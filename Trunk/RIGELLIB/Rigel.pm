#!/usr/bin/env perl -w

#
# Rigel - an RSS to IMAP Gateway
#
# Copyright (C) 2004 Taku Kudo <taku@chasen.org>
#               2005 Yoshinari Takaoka <mumumu@mumumu.org>
#               2008 Greg Ross <greg@darkphoton.com>
#     All rights reserved.
#     This is free software with ABSOLUTELY NO WARRANTY.
#
# You can redistribute it and/or modify it under the terms of the
# GPL2, GNU General Public License version 2.
#

#
# This is the main module for Rigel, it is
# responsible for:
#     - Connecting to the IMAP server
#     - Reading RSS Feeds
#     - Parsing RSS Feeds
#     - Encrypting strings from the command line
#     - Converting HTML to Text
#     - Retreiving feed info from the IMAP server
#     - Adding/Deleting feeds
#     - Filling in variables in to configuration items
#     - Fixing broken feeds if possible
#

require 5.008_000;
use strict;
use Mail::IMAPClient;
use Mail::IMAPClient::BodyStructure;
use XML::FeedPP;
use HTTP::Date;
use RIGELLIB::Unicode;
use RIGELLIB::Config;
use RIGELLIB::Common;
use Data::Dumper;
use Crypt::CBC;
use MIME::Parser;
use Unicode::Map8;
use MIME::WordDecoder;
use HTML::Entities;
use Text::Unidecode;

package RIGELLIB::Rigel;
{
    our $VERSION       = undef;

    # config init.
    our $config_obj    = undef;
    our $GLOBAL_CONFIG = undef;
    our $SITE_CONFIG   = undef;

    sub new {
        my $this       = shift;
        $config_obj    = shift;

        $GLOBAL_CONFIG = $config_obj->get_global_configall();
        $SITE_CONFIG   = $config_obj->get_site_configall();
        $VERSION       = $config_obj->get_version();

        bless $GLOBAL_CONFIG, $this;
    }


    sub connect {
        my $this     = shift;
        my $ssl_sock = undef;

        if ( $this->{'use-ssl'} ) {
            eval 'use IO::Socket::SSL';
            if( $this->is_error() ) {
                print "you specify use SSL but dont install IO::Socket::SSL.\n";
                print "please install it via cpan.\n";
                exit();
            }

            $ssl_sock = IO::Socket::SSL->new("$this->{host}:$this->{port}")
            or die "could not connect to the imap server over ssl.";
        }

        if ( substr( $this->{password}, 0, 16 ) == "53616c7465645f5f" ) {
            my $cipher = Crypt::CBC->new( -key => 'rigel007', -cipher => 'DES_PP', -salt => "rigel007");

            $this->{password} = $cipher->decrypt_hex($this->{password});
        }
        
        my $imap = Mail::IMAPClient->new( Socket        => ( $ssl_sock ? $ssl_sock : undef ),
                                          Server        => $this->{host},
                                          User          => $this->{user},
                                          Port          => $this->{port},
                                          Password      => $this->{password},
                                          Peek          => 1,
                                          Authmechanism => ($this->{'cram-md5'} ? "CRAM-MD5" : undef)
                                         );

        if( !$imap ) {
             die "imap client initialize failed. maybe you dont specify proper option...\n";
        }

        $this->{'directory_separator'} = $imap->separator();

	# Now that we have the directory seperator, update the management
	# folder value and last modified folder value with the proper template 
	# values
        ( $this->{'management-folder'} ) = $this->apply_template( undef, undef, 1, $this->{'management-folder'} );
        ( $this->{'last-modified-folder'} ) = $this->apply_template( undef, undef, 1, $this->{'last-modified-folder'} );

        if ($this->{debug}) {
            $imap->Debug(1);
            $imap->Debug_fh();
        }

        if ( $this->{'use-ssl'} ) {
            $imap->State(1);    # connected
            $imap->login();     # if ssl enabled, login required because it is bypassed.
        }

        # authentication failure. sorry.
        if( !$imap->IsAuthenticated() ) {
            print "Authentication failure, sorry.\n";
            print "connected to : $this->{host}:$this->{port}\n";
            exit();
        }

        $this->{imap} = $imap;
        die "$@ $this->{user}\@$this->{host}\n" unless ($imap);

    }


    sub connect_test {
        my $this = shift;

        $this->connect ();
        $this->{imap}->close ();
    }

    sub encrypt {
        my $this   = shift;
        my $cipher = Crypt::CBC->new( -key => 'rigel007', -cipher => 'DES_PP', -salt => "rigel007");

        print "----Start Encrypted Data----\n", $cipher->encrypt_hex($this->{encrypt}), "\n----End Encrpyted Data----\n";
    }

    sub run {
        my $this = shift;

        # First, connect to the IMAP server
        $this->connect ();

        # Next, check to see if there are any Add/Delete's to process
        $this->process_change_requests();                

        # Finally, load the feeds from the server
        my $site_config_list = $this->get_feeds_from_imap();

        for my $site_config (@{$site_config_list}) {
            $this->{site_config} = $site_config;

            for my $url (@{$site_config->{url}}) {
                my ( $rss, @subject_lines ) = $this->get_rss ($url, $site_config);

                next unless ($rss);

                $this->send ($rss, $site_config, \@subject_lines);
                $this->expire ($rss);
            }
        }

        $this->{imap}->close ();
    }


    sub get_rss {
        my $this        = shift;
        my $link        = shift;
        my $site_config = shift;
        my $imap        = $this->{imap};
        my ($folder)    = $this->apply_template( undef, undef, 1, $this->{'last-modified-folder'} );
        my $headers     = {};

        # start site processing....
        print "processing $link...\n";

        $imap->select( $folder );
        my $message_id = sprintf ('%s@%s', $link, $this->{host});
        my @search = $imap->search ("HEADER message-id \"$message_id\"" );

        if ($this->is_error()) {
            print "WARNING: $@\n";
        }

	my $latest = undef;
	my $lmsg = undef;
	( $latest, $lmsg ) = $this->get_latest_date (\@search);

        # If this site is going to check subject lines against the last
	# update we need to retreive them from the IMAP message that was
	# the last update.
        my @subject_lines = undef;

        if( $site_config->{'use-subjects'} ) {
            # We're going to need a mime parser to retreive the subject list
	    # from the last update data
	    my $mp       = new MIME::Parser;
            my $e;
	    my $subject_glob;

            # setup the message parser so we don't get any errors and we 
            # automatically decode messages
            $mp->ignore_errors(1);
            $mp->extract_uuencode(1);

            eval { $e = $mp->parse_data( $imap->message_string( $lmsg ) ); };

            my $error = ($@ || $mp->last_error);

            if ($error) {
                $subject_glob = "";
            } else {
                # get_mime_text_body will retrevie all the plain text peices of the
                # message and return it as one string.
                $subject_glob = __trim( get_mime_text_body( $e ) );
                $mp->filer->purge;
            }

	    # Now that we have the last updated subject list in a big string, time
	    # to prase it in to an array.
	    my $beyond_headers = 0;
	    foreach my $subject ( split( '\n', $subject_glob ) ) {
	        if( $beyond_headers == 1 ) { push @subject_lines, $subject; }
	        if( $subject eq "" ) { $beyond_headers = 1; }
	    }
        }

	if ($latest)  {
            $headers = { 'If-Modified-Since' => HTTP::Date::time2str ($latest) };
            $site_config->{'last-updated'} = $latest;        
        }

        my $common = RIGELLIB::Common->new();
        my @rss_and_response = $common->getrss_and_response( $link, $headers );

	if( scalar(@rss_and_response) == 0 ) {
	    print "\tNot modified, no update required.\n";
            return;
	}

        foreach my $MessageToDelete (@search ) {
            $imap->delete_message ($MessageToDelete); # delete other messages;
        }

        $imap->expunge();

        my $content = $rss_and_response[0];
        my $response = $rss_and_response[1];
        my $rss = undef;

        # Do some rudimentary checks/fixes on the feed before parsing it
        $content = __fix_feed( $content );

        # Parse the feed
        eval { $rss = XML::FeedPP->new($content); };

        if ($this->is_error()) {
            print "\tFeed error, content will not be created.\n";
            return undef;
        }

	if( $rss ) {
            print "\tModified, updating IMAP items.\n";
        } else { 
            print "\tUnabled to retreive feed, not updating.\n";
        }

        # copy session information
        $rss->{'Rigel:last-modified'} = HTTP::Date::time2str ($response->last_modified);
        $rss->{'Rigel:message-id'}    = $message_id;
        $rss->{'Rigel:rss-link'}      = $link;

        return ( $rss, @subject_lines );
    }


    sub send {
        my $this        = shift;
        my $rss         = shift;
        my $site_config = shift;
	my $subjects    = shift;
        my $imap        = $this->{imap};

        my @items;
	my @subject_lines;
	my @old_subject_lines = @{$subjects};
	my $old_subject_glob = "\n";

	if( $subjects ) {
	    foreach my $old_subject ( @old_subject_lines ) {
	        $old_subject_glob = $old_subject_glob . $old_subject . "\n";
	    }
	}

        my $type = $this->{site_config}->{type};

        if ($type eq "channel") {
            @items = ($rss); # assume that item == rss->channel
        } elsif ($type eq "items") {
            foreach my $one_item ($rss->get_item()) {
                push(@items, $one_item);
            }
        } else {
            print "WARNING: unknown type [$type]!\n";
            return;
        }

        my ($folder) = $this->apply_template ($rss, undef, 1, $this->{site_config}->{folder});
        $folder = $this->get_real_folder_name ($folder, $this->{'directory_separator'});
        $this->select ($folder);

        my @append_items;
        my @delete_mail;
	my $subject;

        for my $item (@items) {
            my $message_id  = $this->gen_message_id ($rss, $item);

            # Get the subject line and add it to our cache for later, make sure we
	    # strip any newlines so we can store it in the IMAP message properly
	    $subject = $this->rss_txt_convert( $item->title() );
	    $subject =~ s/\n//g;
	    push @subject_lines, $subject;

            # Retreive the date from the item or feed for future work.
            my $rss_date = $this->get_date ($rss, $item);

            # Convert the above date to a unix time code
            my $rss_time = HTTP::Date::str2time( $rss_date );

            # if expire enabled, get lastest-modified time of rss.
            if ($this->{site_config}->{expire} > 0) {
                # really expired?
                if (time() - $rss_time > $this->{site_config}->{expire} * 60 * 60 * 24 ) {
                    next;
                };
            }

            # Check to see if the rss item is older than the last update, in otherwords, the user
            # deleted it so we shouldn't add it back in.
            if ( $rss_time > $site_config->{'last-updated'} || $rss_date eq "" ) {
                # message id is "rss url@host" AND x-rss-aggregator field is "Rigel"
                # and not deleted.
                my @search = $imap->search ("NOT DELETED HEADER message-id \"$message_id\" HEADER x-rss-aggregator \"Rigel\"");

                if ($this->is_error()) {
                    print "WARNING: $@\n";
                    next;
                }

                # if message not found, append it.
                if (@search == 0) {
		    if( $site_config->{'use-subjects'} ) {
                        # if the subject check is enabled, validate the current subject line
                        # against the old subject lines
                        if( $old_subject_glob !~ m/$subject/ ) {
			    push @append_items, $item;
			}
		    } else {
		        push @append_items, $item;
		    }

                } else {
                    next unless ($rss_date); # date filed is not found, we ignore it.

                    # get last-modified_date of IMAP search result.
                    my $latest = $this->get_latest_date (\@search);

                    # if rss date is newer, delete search result and add rss items.
                    # by this, duplicate message is replaced with lastest one.
                    if ( $rss_time > $latest ) {
                        push @delete_mail, @search;
                        push @append_items, $item;
                    }
                }
            }
        }

        # delete items, if sync functionality is enabled
        if ($this->{site_config}->{'sync'}) {
            my %found = ();
            for my $item (@items) {
                $found{$item->link()} = 1;
            }

            my $link = $rss->{'Rigel:rss-link'};
            my @search = $imap->search ("HEADER x-rss-link \"$link\" HEADER x-rss-aggregator \"Rigel\"");

            for my $msg (@search) {
                my $link2 = $imap->get_header ($msg, "x-rss-item-link");
                $link2 =~ s/^\s*//g; $link2 =~ s/\s*$//g; # must trim spaces, bug of IMAP server?
                unless ($found{$link2}) {
                    push @delete_mail, $msg;
                }
            }
        }

        # update all message
        foreach my $MessageToDelete (@delete_mail) {
            $imap->delete_message( $MessageToDelete );
        }

        $imap->expunge( $folder );

        for my $item (@append_items) {
            $this->send_item ($folder, $rss, $item);
        }

        my $ItemsUpdated = scalar( @append_items );
        if( $ItemsUpdated > 0 ) {
            print "\tAdded $ItemsUpdated articles.\n";
        } else {
	    print "\tNo items found to add.\n";
	}

        $this->send_last_update ($rss, \@subject_lines);

        return;
    }


    sub expire {
        my $this   = shift;
        my $rss    = shift;
        my $expire = $this->{site_config}->{expire} || -1;
        my $imap   = $this->{imap};

        return if ($expire <= 0);

        my ($folder, $expire_folder) = $this->apply_template ($rss, undef, 1, $this->{site_config}->{folder}, $this->{site_config}->{'expire-folder'});
        $folder        = $this->get_real_folder_name ($folder, $this->{'directory_separator'});
        $expire_folder = $this->get_real_folder_name ($expire_folder, $this->{'directory_separator'}); 

        my $key = Mail::IMAPClient->Rfc2060_date (time() - $expire * 60 * 60 * 24);

        my $query = (defined $this->{site_config}->{'expire-unseen'}) ? "SENTBEFORE $key" : "SEEN SENTBEFORE $key";
        $query .= " HEADER x-rss-aggregator \"Rigel\"";

        $this->select ($folder);
        my @search = $imap->search ($query);

        if ($this->is_error()) {
            print "WARNING: $@\n";
            return;
        }

        return if (@search == 0);

        if ($this->{site_config}->{'expire-folder'} && $expire_folder ) {
            $this->create_folder ($expire_folder);
            for my $msg (@search) {
                print "  moving: $msg -> $expire_folder\n";
                $imap->move ($expire_folder, $msg);
            }
        } else {
            print "  deleting: [@search]\n";
            $imap->delete_message (@search);
        }
    }


    sub get_latest_date {
        my $this   = shift;
        my $list   = shift;
        my $header = shift || 'date';

	my $imap   = $this->{imap};
	my $lmsg   = undef;
        my $latest = -1;

        for my $msg (@{$list}) {
            my $date = $imap->get_header ($msg, $header);
            next unless ($date);
            $date = HTTP::Date::str2time ($date);
            if ($date > $latest) {
	        $latest = $date;
		$lmsg = $msg;
	    }
        }

        if ($latest == -1) {
	    $latest = undef; 
	    $lmsg = undef;
	} 

        return ( $latest, $lmsg);
    }


    sub send_last_update {
        my $this          = shift;
        my $rss           = shift;
	my $subject_lines = shift;

        my $message_id    = $rss->{'Rigel:message-id'};
        my $date          = $rss->{'Rigel:last-modified'};
        my $link          = $rss->{'Rigel:rss-link'};
        my $a_date        = scalar (localtime ());

        my $body =<<"BODY"
From: Rigel@
Subject: $link
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
Content-Base: $link
Message-Id: $message_id
Date: $date
User-Agent: Rigel version $VERSION
X-RSS-Link: $link
X-RSS-Aggregator: Rigel-checker
X-RSS-Aggregate-Date: $a_date;
X-RSS-Last-Modified: $date

Link: $link
Last-Modified: $date
Aggregate-Date: $a_date

BODY
;
	my $subject;

	# Add the subject lines from the update so we can skip
	# these articles if required on the next update
	foreach $subject (@{$subject_lines}) {
		$body = $body . $subject . "\n";
	}

        my ($folder) = $this->apply_template( undef, undef, 1, "%{dir:lastmod}" );
        $this->{imap}->select( $folder );
        my $uid = $this->{imap}->append_string ($folder, $body);

	$this->{imap}->Uid(1);
        $this->{imap}->see ( $uid );
        $this->{imap}->Uid(0);
    }


    sub send_item {
        my $this        = shift;
        my $folder      = shift;
        my $rss         = shift;
        my $item        = shift;

        my $headers = $this->get_headers($rss, $item);

        my $body = ($this->{site_config}->{'delivery-mode'} eq 'text')
                 ? $this->get_text_body( $rss, $item )
                 : $this->get_html_body( $rss, $item );

        my $message = ($headers . $body);
        utf8::encode($message);  # uft8 flag off.
        $this->{imap}->append_string($folder, $message);
    }


    sub get_headers {
        my $this        = shift;
        my $rss         = shift;
        my $item        = shift;

        my $date       = $this->get_date ($rss, $item);
        my $rss_date   = $this->get_rss_date ($rss, $item) || "undef";

        my $subject    = $this->{site_config}->{subject};
        my $from       = $this->{site_config}->{from};
        my $to         = $this->{site_config}->{to};
        my $message_id = $this->gen_message_id ($rss, $item);

        ($subject, $from) = $this->apply_template ($rss, $item, undef, $subject, $from);

        my $mime_type;

        if( $this->{site_config}->{'delivery-mode'} eq 'text' ) {
            $mime_type = 'text/plain';

            # Since we're delivering in plain text, make sure that
            # the subject line didn't get poluted with html from the
            # rss feed.
            $subject = $this->rss_txt_convert( $subject );
        } else {
            $mime_type = 'text/html';
        }

        # if line feed character include, some mailer make header broken.. :<
        $subject =~ s/\n//g;

        my $m_from    = RIGELLIB::Unicode::to_mime ($from);
        my $m_subject = RIGELLIB::Unicode::to_mime ($subject);
        my $m_to      = RIGELLIB::Unicode::to_mime ($to);
        my $a_date    = scalar(localtime ());
        my $l_date    = $rss->{'Rigel:last-modified'} || $a_date;
        my $link      = $rss->{'Rigel:rss-link'} || "undef";

        my $return_headers =<<"BODY"
From: $m_from
Subject: $m_subject
To: $m_to
MIME-Version: 1.0
Content-Type: $mime_type; charset="UTF-8"
Content-Transfer-Encoding: 8bit
Content-Base: $link
Message-Id: $message_id
Date: $date
User-Agent: Rigel version $VERSION
X-RSS-Link: $link
X-RSS-Channel-Link: $rss->{channel}->{link}
X-RSS-Item-Link: $link
X-RSS-Aggregator: Rigel
X-RSS-Aggregate-Date: $a_date
X-RSS-Last-Modified: $l_date;

BODY
;

        return $return_headers;
    }


    sub get_text_body {
        my $this       = shift;
        my $rss        = shift;
        my $item       = shift;

        my $subject    = $this->{site_config}->{subject};
        my $from       = $this->{site_config}->{from};
        my $desc       = $this->get_description( $item );

        ($subject, $from) = $this->apply_template ($rss, $item, undef, $subject, $from);

        # convert html tag to appropriate text.
        $subject = $this->rss_txt_convert( $subject );
        $desc    = $this->rss_txt_convert( $desc );

        my $link = $item->link();

        # Get rid of any newlines in the subject or link
        $subject =~ s/\n//g;
        $link =~ s/\n//g;

        my $return_text_body = $subject . "\n";

        $return_text_body .= "-" x length( $subject ) . "\n";
        $return_text_body .= "$desc\n" if ($desc);
        $return_text_body .= "\n$link";

        return $return_text_body;
    }


    sub get_html_body {
        my $this       = shift;
        my $rss        = shift;
        my $item       = shift;
        
        my $subject    = $this->{site_config}->{subject};
        my $from       = $this->{site_config}->{from};
        my $desc       = $this->get_description( $item );

        ($subject, $from) = $this->apply_template ($rss, $item, undef, $subject, $from);

        my $link = $item->link();

        my $return_body =<<"BODY"
<html>
<head>
<title>$subject</title>
<style type="text/css">
body {
      margin: 0;
      border: none;
      padding: 0;
}
iframe {
  position: fixed;
  top: 0;
  right: 0;
  bottom: 0;
  left: 0;
  border: none;
}
</style>
</head>
<body>
<iframe width="100%" height="100%" src="$link">
$desc
</iframe>
</body>
</html>
BODY
;

        return $return_body;
    }


    sub rss_txt_convert {
        my $this = shift;
        my $string = shift;

        return "" if ( !$string );

        # First convert any less than or greater than tags that have been encoded 
        # back to real characters
        $string =~ s/&lt;/\</mg;
        $string =~ s/&gt;/\>/mg;

        # Convert any new line/carrige returns to html breaks because most feeds
        # mix HTML with plain text, this causes lines to break in weird ways so
        # first converting all new lines to BR's makes sense
        $string =~ s/\r//g;
        $string =~ s/\n/\<BR\>/g;

        # Remove all address tags?
        $string =~ s/<a .*?>([^<>]*)<\/a>/$1/ig;

        # Convert Heading tags to paragraph marks, this just let's us do a single
        # replace later to convert them to double new line entries and lets the
        # next set of code to removed paragraph open/close pairs work on Heading
        # tags as well
        $string =~ s/\<(\/)?H.\s*\>/\<p\>/mgi;

        # Replace any open/close paragraph mark pairs with just an open mark, as 
        # we don't want to have 4 new lines, just two.
        $string =~ s/\<P(\s*\/)?\>\<\/P(\s*\/)?\>/\<p\>/mgi;

        # Replace any paragraph marks with double new lines.  We still need to 
        # replace both open and close marks as, yet again, most sites mix plain
        # text and html and expect it to look right.
        $string =~ s/\<(\/)?P(\s*\/)?\>/\n\n/mgi;

        # Replace any line breaks with single new lines
        $string =~ s/\<(\/)?(BR)(\s*\/)?\>/\n/mgi;

        #
        # All HTML Tag but anchor will be deleted!!
        # shamelessly stolen from 
        # http://www.din.or.jp/~ohzaki/perl.htm#Tag_Remove
        #
        my $text_regex = q{[^<]*};
        my $tag_regex_ = q{[^"'<>]*(?:"[^"]*"[^"'<>]*|'[^']*'[^"'<>]*)*(?:>|(?=<)|$(?!\n))}; #'}}}};
        my $comment_tag_regex = '<!(?:--[^-]*-(?:[^-]+-)*?-(?:[^>-]*(?:-[^>-]+)*?)??)*(?:>|$(?!\n)|--.*$)';
        my $tag_regex = qq{$comment_tag_regex|<$tag_regex_};
        my $result = '';
        while ($string =~ /($text_regex)($tag_regex)?/gso) {
            last if $1 eq '' and $2 eq '';
            $result .= $1;
            my $tag_tmp = $2;
            if ($tag_tmp =~ /^<(XMP|PLAINTEXT|SCRIPT)(?![0-9A-Za-z])/i) {
                $string =~ /(.*?)(?:<\/$1(?![0-9A-Za-z])$tag_regex_|$)/gsi;
                (my $text_tmp = $1) =~ s/</&lt;/g;
                $text_tmp =~ s/>/&gt;/g;
                $result .= $text_tmp;
            }
        }

        # Now that we have a mostly clean text string, we just need
        # to clear out any HTML entities that are left, like &nbsp;
        # etc.  The decode_entities catches all of these including
        # hex and decimal representation.
        $string = HTML::Entities::decode_entities( $result );

	# Now that we have a Unicode string, we need to convert it
	# back to ASCII so nothing breaks when we do something like
	# save it to an IMAP message
	$string = Text::Unidecode::unidecode( $string );

        return $string;
    }


    # wrappers
    sub select {
        my $this   = shift;
        my $folder = shift;

        $this->create_folder ($folder);
        $this->{imap}->select ($folder) || print "@!\n";
    }


    sub create_folder {
        my $this   = shift;
        my $folder = shift;
        my $imap = $this->{imap};

        unless ($imap->exists($folder)) {
            $imap->create ($folder) || print "WARNING: $@\n";
        }
    }


    # misc functions
    sub gen_message_id {
        my $this = shift;
        my $rss  = shift;
        my $item = shift;

        return sprintf ('%s@%s', __trim( $item->link() ), $this->{host});
    }


    sub is_error {
        # if you use windows, FCNTL error will be ignored.
        if( !$@ || ( $^O =~ /Win32/ && $@ =~ /fcntl.*?f_getfl/ ) ) {
            return 0;
        }

        return 1;
    }


    sub get_rss_date {
        my $this = shift;
        my $rss  = shift;
        my $item = shift;

        # priority of rss last-modified-date is ...
        # 1. item -> 2. channel -> 3. http header.
        # http header is the last resort!
        #
        # dc:date is derived from rss 1.0 specification
        # pubDate, lastbuilddate are derived from rss 0.91 rev 3, rss 2.0
        #
        return $item->pubDate()
            || $rss->pubDate()
            || undef;
    }


    sub get_date {
        my $this = shift;
        my $rss  = shift;
        my $item = shift;
        my $date = $this->get_rss_date ($rss, $item) || "";

        return HTTP::Date::time2str(HTTP::Date::str2time ($date));
    }


    sub get_description {
        my $this = shift;
        my $item = shift;

        return $item->description();
    }


    sub get_real_folder_name {
        my $this   = shift;
        my $str    = shift;
        my $dirsep = shift;

        if ($this->{prefix}) {
            $str = sprintf ("%s%s%s",
                            RIGELLIB::Unicode::to_utf8 ($this->{prefix}),
                            $dirsep,
                            $str);
        } else {
            $str =~ s#\.#$dirsep#g;
        }

        # omit last separator.
        if ($str ne $dirsep) {
            $str =~ s#$dirsep$##;
        }

        return RIGELLIB::Unicode::to_utf7($str);
    }

    sub get_feeds_from_imap {
        my $this = shift;

        my $message;
        my $feedconf;
        my $e;
        my @messages;
        my @config_list;
        my %config;
        my ($folder) = $this->apply_template( undef, undef, 1, "%{dir:manage}%{dir:sep}Configuration" );
        my $mp       = new MIME::Parser;

        # setup the message parser so we don't get any errors and we 
        # automatically decode messages
        $mp->ignore_errors(1);
        $mp->extract_uuencode(1);

        $this->{imap}->select( $folder );

        @messages = $this->{imap}->messages();
                
        foreach $message (@messages) {
            # Retreive the complete message and run it through the MIME parser
            eval { $e = $mp->parse_data( $this->{imap}->message_string( $message) ); };
            my $error = ($@ || $mp->last_error);

            if ($error) {
                $feedconf = "";
            } else {
                # get_mime_text_body will retrevie all the plain text peices of the
                # message and return it as one string.
                $feedconf = __trim( get_mime_text_body( $e ) );
                $mp->filer->purge;
            }

            # parse the configuration options in to a configuration object
            %config = $config_obj->parse_url_list_from_string( $feedconf );
            push @config_list, { %config };
        }
        
        return \@config_list;
    }

    sub get_mime_text_body {
        my $ent = shift;

        my $text;
        my $wd;
        my $map = Unicode::Map8->new('ASCII') or die "Cannot create character map\n";

        if (my @parts = $ent->parts) {
            return get_mime_text_body($_) for @parts;
        } elsif (my $body = $ent->bodyhandle) {
            my $type = $ent->head->mime_type;

            if ($type eq 'text/plain') { 
                if ($ent->head->get('Content-Type') and $ent->head->get('Content-Type') =~ m!charset="([^\"]+)"!) {
                    $wd = supported MIME::WordDecoder uc $1;
                }

                $wd = supported MIME::WordDecoder "ISO-8859-1" unless $wd;

                return $text .  $map->to8($map->to16($wd->decode($body->as_string||'')));
            }
        }
    }

    sub apply_template {
        my $this       = shift;
        my $rss        = shift;
        my $item       = shift;
        my $folder_flg = shift;

        my @from       = @_;
        my %cnf;

        if ($rss) {
            $cnf{'channel:title'}       = $rss->title();
            $cnf{'channel:link'}        = $rss->link();
            $cnf{'channel:description'} = $rss->description();
            $cnf{'channel:dc:date'}     = $rss->pubDate() || "";

            $cnf{'dashline:channel:title'} = "-" x length( $cnf{'channel:title'} );
        }

        if ($item) {
            $cnf{'item:description'}  = $item->description();
            $cnf{'item:link'}         = $item->link();
            $cnf{'item:title'}        = $item->title();
            $cnf{'item:dc:date'}      = $item->pubDate();
            $cnf{'item:dc:subject'}   = $item->category();
            $cnf{'item:dc:creator'}   = $item->author();

            $cnf{'dashline:item:title'} = "-" x length( $cnf{'item:title'} )
	}

        $cnf{host}            = $this->{host};
        $cnf{user}            = $this->{user};
        $cnf{'last-modified'} = $rss->{'Rigel:last-modified'};
        $cnf{'rss-link'}      = $rss->{'Rigel:rss-link'};
        $cnf{'dir:sep'}       = $this->{'directory_separator'};
        $cnf{'dir:manage'}    = $this->{'management-folder'};
        $cnf{'dir:lastmod'}   = $this->{'last-modified-folder'};
	$cnf{'newline'}       = "\n";

        my @result;
        for my $from (@from) {
            if ($from) {
                for my $key (keys %cnf) {
                    next unless ($cnf{$key});
                    $cnf{$key} =~ s/\./:/g if ($folder_flg);
                    my $key2 = "%{" . $key . "}";
                    $from =~ s/$key2/$cnf{$key}/eg;
                }

		$from =~ s/%{.*}//g;
            }

            push @result, $from;
        }

        return @result;
    }

    sub process_change_requests() {
        my $this = shift;

        my @messages;
        my $message;
        my $feedconf;
        my @config_list;
        my %config;
        my $siteurl;
        my $uid;
        my ($AddFolder) = join( '', $this->apply_template( undef, undef, 1, "%{dir:manage}%{dir:sep}Add" ) );
        my ($DeleteFolder) = join( '', $this->apply_template( undef, undef, 1, "%{dir:manage}%{dir:sep}Delete" ) );
        my ($ConfigFolder) = join( '', $this->apply_template( undef, undef, 1, "%{dir:manage}%{dir:sep}Configuration" ) );
        my ($LastModFolder) = join( '', $this->apply_template( undef, undef, 1, "%{dir:lastmod}" ) );

        $this->create_folder( $AddFolder );
        $this->create_folder( $DeleteFolder );
        $this->create_folder( $ConfigFolder );
        $this->create_folder( $LastModFolder );

        $this->{imap}->select( $AddFolder );
        @messages = $this->{imap}->messages();

        foreach $message (@messages) {
            $feedconf = "";
            $feedconf = __trim( $this->{imap}->bodypart_string( $message, 1 ) );
            %config = $config_obj->parse_url_list_from_string( $feedconf );

            $siteurl = "";
            foreach my $site (@{$config{url}}) {
                $siteurl = $siteurl . $site;
            }

	    $siteurl = __trim( $siteurl );

            if ($siteurl ne "http://template") {
                my $headers =<<"BODY"
From: Rigel@
Subject: $siteurl
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
User-Agent: Rigel version $VERSION
BODY
;
                $this->{imap}->append_string( $ConfigFolder, $headers . "\n" . $feedconf );
                $this->{imap}->delete_message( $message );
            }
        }

        # You can't change the folder during the above loop or the return
        # from messages() becomes invalid, so loop thorugh all the messages
        # in the config folder and mark them all as read
        $this->{imap}->select( $ConfigFolder );
        
        foreach $message ($this->{imap}->messages()) {
            $this->{imap}->see( $message );
        }

        # Now expunge any deleted messages
        $this->{imap}->select( $AddFolder );
        $this->{imap}->expunge( $AddFolder );  # For some reason the folder has to be passed here otherwise the expunge fails

        # Now fill in any extra template messages we need
        my $template_message =<<"BODY"
From: Rigel@
Subject: http://template
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
User-Agent: Rigel version $VERSION

http://template

#folder = RSS%{dir:sep}%{channel:title}
#type = items
#to = 
#subject = %{item:title}
#from = 
#delivery-mode = html
#expire-unseen = undef
#expire = -1
#expire-folder = undef
#sync = undef
#last-update = undef
#use-subjects = undef
#last-subjects = undef
BODY
;
        my $i = 10 - $this->{imap}->message_count( $AddFolder );
        for ( ; $i != 0; $i-- ) {
            $uid = $this->{imap}->append_string( $AddFolder, $template_message );
            $this->{imap}->Uid(1);
            $this->{imap}->see ( $uid );
            $this->{imap}->Uid(0);
        }

        $this->{imap}->select( $DeleteFolder );
        @messages = $this->{imap}->messages();

        my $Subject;
        my $message_id;
        my @search;
        my $modified;
        my @FeedsToDelete;

        foreach $message (@messages) {
            push @FeedsToDelete, $this->{imap}->subject( $message );
            $this->{imap}->delete_message( $message );
            $this->{imap}->expunge( $DeleteFolder );
            }

        $this->{imap}->select( $LastModFolder );
        foreach $Subject (@FeedsToDelete) {
            $message_id = sprintf ('%s@%s', $Subject, $this->{host});
            @search = $this->{imap}->search ("UNDELETED HEADER message-id \"$message_id\" HEADER x-rss-aggregator \"Rigel-checker\"");

            foreach $modified (@search) {
                $this->{imap}->delete_message( $modified );
                $this->{imap}->expunge();
            }
        }

        return;
    }

    sub __fix_feed() {
        my $content  = shift;
        
        my $fixed;
        my $count;

        # First, strip any spaces from feed
        $fixed = __trim( $content );

        # if the opening xml tag is missing, add it
        $count = 0;
        while ($fixed =~ /\<\?xml/gi) { $count++ }
        if ( $count == 0  ) {
            $fixed = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" . $fixed;
        }

        # Make sure we don't have duplicate closing channel tags
        $count = 0;
        while ($fixed =~ /\<\/channel\>/gi) { $count++ }
            if ( $count > 1  ) {
                for( my $i = 1; $i < $count; $i++ ) {
                    $fixed =~ s/\<\/channel\>//i;
                }
            }

        # Make sure we don't have duplicate closing rss tags
        $count = 0;
        while ($fixed =~ /\<\/rss\>/gi) { $count++ }
            if ( $count > 1  ) {
                for( my $i = 1; $i < $count; $i++ ) {
                    $fixed =~ s/\<\/rss\>//i;
                }
            }
            
        return $fixed;
    }

    sub __trim() {
        my $str = shift;

        return undef if( !defined $str );

        chomp $str;
        $str =~ s/^\s*//;
        $str =~ s/\s*$//;

        return $str;
    }

}

1;
