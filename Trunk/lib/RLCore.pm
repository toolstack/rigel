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
#     - Fixing broken feeds if possible
#

require 5.008_000;

package RLCore;
    {
    use strict;
    use Mail::IMAPClient;
    use Mail::IMAPClient::BodyStructure;
    use XML::FeedPP;
    use RLUnicode;
    use RLConfig;
    use RLCommon;
    use RLDebug;
    use RLMHTML;
    use RLIMAP;
    use RLTemplates;
    use Crypt::CBC;
    use HTTP::Date;
    use MIME::Parser;
    use MIME::WordDecoder;
    use HTML::Entities;
    use Text::Unidecode;
    use HTML::FormatText::WithLinks::AndTables;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(InitCore Encrypt UpdateFeeds);

    our $VERSION       = undef;

    # config init.
    our $GLOBAL_CONFIG = undef;
    our $SITE_CONFIG   = undef;
    our $IMAP_CONNECT  = undef;

    #
    # This function sets up the various priavte variables to the
    # module.
    #
    #     RLCore::InitCore()
    #
    sub InitCore
        {
        $GLOBAL_CONFIG = RLConfig::GetGlobalConfig();
        $SITE_CONFIG   = RLConfig::GetSiteConfig();
        $VERSION       = RLConfig::GetVersion();
        }

    #
    # This function encrypts a string so that it can be used in the
    # configuration file for a password
    #
    #     RLCore::Encrypt()
    #
    sub Encrypt
        {
        my $cipher = Crypt::CBC->new( -key => 'rigel007', -cipher => 'DES_PP', -salt => "rigel007");

        RLCommon::LogLine( "----Start Encrypted Data----\r\n" );
        RLCommon::LogLine( $cipher->encrypt_hex( $GLOBAL_CONFIG->{encrypt} ) );
        RLCommon::LogLine( "\r\n----End Encrpyted Data----\r\n" );
        }

    #
    # This function is the main part of Rigel, it loops through the feeds and
    # updates the IMAP folders
    #
    #     RLCore::UpdateFeeds()
    #
    sub UpdateFeeds
        {
        # First, connect to the IMAP server
        $IMAP_CONNECT = RLIMAP::IMAPConnect( $GLOBAL_CONFIG );

        # Next, verify that the help messages exist and are up to date
        __VerifyHelp();

        # Next, check to see if there are any Add/Delete's to process
        __ProcessChangeRequests();

        # Finally, load the feeds from the server
        my $site_config_list = __GetFeedsFromIMAP();

        # Update the IMAP configuration messages if it's been requested.
        # otherwise process the feeds normally.
        if( $GLOBAL_CONFIG->{'config-update'} )
            {
            RLCommon::LogLine( "Updating the IMAP configuration messages...\r\n" );
            RLConfig::UpdateConfig( $IMAP_CONNECT, $site_config_list );
            }
        else
            {
            for my $site_config (@{$site_config_list})
                {
                my ( $rss, $ttl, @subject_lines ) = __GetRSS( $site_config->{url}, $site_config );

                if( !$rss )
                    {
                    next;
                    }

                __SendFeed( $rss, $site_config, $ttl, \@subject_lines );
                __ExpireFeed( $rss, $site_config );
                }
            }
            
        RLCommon::SendLogFile( $IMAP_CONNECT );

        $IMAP_CONNECT->close();
        }

    ###########################################################################
    #  Internal Functions only from here
    ###########################################################################

    #
    # This function does the grunt work of getting the feed, ensuring TTL's
    # are handled and if any updates need to be made
    #
    #     __GetRSS( $url, $site_config )
    #
    # Where:
    #     $url is the url of the feed
    #     $site_config is the configuration to use for this feed
    #
    sub __GetRSS
        {
        my $link        = shift;
        my $reallink    = RLConfig::ApplyTemplate( undef, undef, 1, $link );
        my $site_config = shift;
        my $folder      = RLConfig::ApplyTemplate( undef, undef, 1, $GLOBAL_CONFIG->{'last-modified-folder'} );
        my $headers     = {};

        # start site processing....
        RLCommon::LogLine( "\r\nprocessing '$site_config->{'desc'}'...\r\n" );

        $folder = RLIMAP::GetRealFolderName( $folder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "last update folder: $folder" );
        $IMAP_CONNECT->select( $folder );

        my $message_id = sprintf('%s@%s', $link, $GLOBAL_CONFIG->{host} );
        my @search = $IMAP_CONNECT->search( "HEADER message-id \"$message_id\"" );
        RLDebug::OutputDebug( 2, "HEADER message-id \"$message_id\"" );

        if( RLCommon::IsError() )
            {
            RLCommon::LogLine( "WARNING: $@\r\n" );
            }

        my $latest = undef;
        my $lmsg = undef;
        ( $latest, $lmsg ) = RLIMAP::GetLatestDate( $IMAP_CONNECT, \@search );
        RLDebug::OutputDebug( 2, "Message search: ", \@search );
        RLDebug::OutputDebug( 2, "Latest message: $lmsg" );

        # First, let's see if any TTL has been idenfitifed for this feed
        my $rss_ttl = 0;

        if( $lmsg && ( $site_config->{'force-ttl'} == -1 ) )
            {
            $rss_ttl = $IMAP_CONNECT->get_header( $lmsg, "X-RSS-TTL" );
            RLDebug::OutputDebug( 1, "Cached TTL = $rss_ttl" );

            # The RSS TTL is expressed in minutes, and the latest is expressed
            # in seconds, so take the latest and add the ttl in seconds to it
            # for use later in get_rss_and_response
            $rss_ttl = $latest + ( $rss_ttl * 60 );
            RLDebug::OutputDebug( 1, "New TTL epoch = " . HTTP::Date::time2str( $rss_ttl ) );
            }
        else
            {
            # if there was no chaced status message, then this is really the first
            # update and we should leave the rss_ttl value to 0 so a site update
            # is done, otherwise we can use the force-ttl value to set a new epoch
            if( $lmsg )
                {
                $rss_ttl = $latest + ( $site_config->{'force-ttl'} * 60 );
                }
            RLDebug::OutputDebug( 1, "TTL forced to " . $site_config->{'force-ttl'} );
            RLDebug::OutputDebug( 1, "New TTL epoch = " . HTTP::Date::time2str( $rss_ttl ) );
            }

		# if we have a status update message and we're not disabling the TTL, add the if modified header
        if( $latest )
            {
			if( $site_config->{'force-ttl'} != 0 )
				{
				$headers = { 'If-Modified-Since' => HTTP::Date::time2str( $latest ) };
				}
				
            $site_config->{'last-updated'} = $latest;
            }

        # Check to see if we should update based upon the RSS TTL value
        my $ctime              = time();
        my $content            = "";
        my $feed_last_modified = 0;
        
        RLDebug::OutputDebug( 2, "Is $rss_ttl > $ctime ?" );
        if( $rss_ttl > $ctime )
            {
            # Not time to update
            RLCommon::LogLine( "\tTTL not yet expired, no update required.\r\n" );
            return ( undef, undef, undef );
            }
        else
            {
            # If this is a webpage instead of an RSS feed, create a temporary RSS
            # feed for it
            if( $site_config->{'body-source'} eq 'webpage' )
                {
                $content = __CreateRSSFeed( $reallink, $site_config );
                $feed_last_modified = time();
                }
            else
                {
                # We're good to go, get the update
                RLDebug::OutputDebug( 1, "RealLink: $reallink\r\n" );
                my @rss_and_response = RLCommon::GetRSS( $reallink, $headers, $rss_ttl );
                
                # If we get a response, setup the content and feed_last_modifed variables.
                if( scalar( @rss_and_response ) > 0 )
                    {
                    $content = $rss_and_response[0];
                    my $response = $rss_and_response[1];
                    $feed_last_modified = $response->last_modified;
                    
                    # if the response didn't have a last_modified time, set it to 
                    # the current time so new items will get added.
                    if( $feed_last_modified == undef )
                        {
                        $feed_last_modified = time();
                        }
                    }
                }
                
            # If we didn't actually get an update from the feed, just return undef's
            RLDebug::OutputDebug( 2, "Feed last modified: " . $feed_last_modified );
            if( $feed_last_modified == 0 )
                {
                RLCommon::LogLine( "\tFeed not modified, no update required.\r\n" );
                return (undef, undef, undef);
                }
            }

        # If this site is going to check subject lines against the last
        # update we need to retreive them from the IMAP message that was
        # the last update.
        my @subject_lines = undef;

        if( $site_config->{'use-subjects'} )
            {
            # We're going to need a mime parser to retreive the subject list
            # from the last update data
            my $mp       = new MIME::Parser;
            my $e;
            my $subject_glob;

            RLDebug::OutputDebug( 1, "Enabled subject caching" );

            # setup the message parser so we don't get any errors and we
            # automatically decode messages
            $mp->ignore_errors( 1 );
            $mp->extract_uuencode( 1 );

            if( $lmsg )
                {
                eval { $e = $mp->parse_data( $IMAP_CONNECT->message_string( $lmsg ) ); };

                my $error = ($@ || $mp->last_error);

                if ($error)
                    {
                    $subject_glob = "";
                    }
                else
                    {
                    # get_mime_text_body will retrevie all the plain text peices of the
                    # message and return it as one string.
                    $subject_glob = RLCommon::StrTrim( __GetMIMETextBody( $e ) );
                    $mp->filer->purge;
                    }
                }
            else
                {
                $subject_glob = "";
                }

            RLDebug::OutputDebug( 1, "subject glob = $subject_glob" );

            # Now that we have the last updated subject list in a big string, time
            # to prase it in to an array.
            my $beyond_headers = 0;
            foreach my $subject ( split( '\r\n', $subject_glob ) )
                {
                if( $beyond_headers eq 1 )
                    {
                    push @subject_lines, $subject;
                    RLDebug::OutputDebug( 1, "subject line = $subject" );
                    }

                if( $subject eq "" ) { $beyond_headers = 1; }
                }
            }

        my $rss = undef;
        my $ttl = 0;

        # Do some rudimentary checks/fixes on the feed before parsing it
        RLDebug::OutputDebug( 1, "Fix feed for common errors..." );
        $content = __FixFeed( $content );
        RLDebug::OutputDebug( 1, "Fix feed complete." );

        # As FeedPP doesn't understand TTL values in the feed, check to see
        # if one exists and get it for later use
        if( $content =~ /.*\<ttl\>(.*)\<\/ttl\>.*/i)
            {
            $ttl = $1;
            RLDebug::OutputDebug( 1, "Feed has TTL! Set to: " . $ttl );
            }

        # Parse the feed
        eval { $rss = XML::FeedPP->new( $content ); };

        if( RLCommon::IsError() )
            {
            RLCommon::LogLine( "\tFeed error, content will not be created.\r\n" );
            return ( undef, $ttl, @subject_lines );
            }

        if( $rss )
            {
            RLCommon::LogLine( "\tModified, updating IMAP items.\r\n" );
            }
        else
            {
            RLCommon::LogLine( "\tUnabled to retreive feed, not updating.\r\n" );
            return ( undef, $ttl, @subject_lines );
            }

        # Now that we've verifyed that we have a feed to process, let's
        # delete the last update info from the IMAP server
        foreach my $MessageToDelete (@search )
            {
            RLDebug::OutputDebug( 2, "Delete meesage: " . $MessageToDelete );
            $IMAP_CONNECT->delete_message( $MessageToDelete ); # delete other messages;
            }

        RLDebug::OutputDebug( 2, "Expunge the mailbox!" );
        $IMAP_CONNECT->expunge();

        # copy session information
        $rss->{'Rigel:last-modified'} = HTTP::Date::time2str( $feed_last_modified );
        $rss->{'Rigel:message-id'}    = $message_id;
        $rss->{'Rigel:rss-link'}      = $link;

        return ( $rss, $ttl, @subject_lines );
        }

    #
    # This function does the grunt work of sending the mail message to the IMAP
    # server as well as cleaning up old articles if required and updating the last
    # update information.
    #
    #     __SendFeed( $rss, $site_config, $ttl, $subjects )
    #
    # Where:
    #     $rss is the feed as a string
    #     $site_config is the configuration to use for this feed
    #     $ttl is the current time to live for the feed
    #     $subjects is the currnet list of subjects from the lastupdate
    #
    sub __SendFeed
        {
        my $rss         = shift;
        my $site_config = shift;
        my $ttl         = shift;
        my $subjects    = shift;

        my @items;
        my @subject_lines;
        my @old_subject_lines = @{$subjects};
        my $old_subject_glob = "\n";

		# Check to make sure the IMAP connection is still active
		if( $IMAP_CONNECT->IsUnconnected() )
			{
			$IMAP_CONNECT->reconnect();
			}
		
        # Re-globify the old subject lines for easier searching later if we
        # have any
        if( $subjects )
            {
            foreach my $old_subject ( @old_subject_lines )
                {
                $old_subject_glob = $old_subject_glob . $old_subject . "\n";
                }
            }

        RLDebug::OutputDebug( 2, "old subject glob = \r\n$old_subject_glob" );
        my $type = $site_config->{type};

        if( $type eq "channel" )
            {
            @items = ($rss); # assume that item == rss->channel
            }
        elsif( $type eq "items" )
            {
            foreach my $one_item ($rss->get_item())
                {
                push( @items, $one_item );
                }
            }
        else
            {
            RLCommon::LogLine( "WARNING: unknown type [$type]!\r\n" );
            return;
            }

        my $folder = RLConfig::ApplyTemplate( $rss, undef, 1, $site_config->{folder} );
        $folder = RLIMAP::GetRealFolderName( $folder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 1, "IMAP folder to use = $folder" );
        RLIMAP::IMAPSelectFolder( $IMAP_CONNECT, $folder );

        my @append_items;
        my @delete_mail;
        my $subject;
        my $item;
        my $start;
        my $increment;
        my $end;

        if( $site_config->{'article-order'} != 1 )
            {
            $start = @items - 1;
            $increment = -1;
            $end = -1;
            }
        else
            {
            $start = 0;
            $increment = 1;
            $end = @items;
            }

        for( my $i = $start; $i != $end; $i = $i + $increment )
            {
            $item = $items[$i];
            my $message_id  = __GenerateMessageID( $rss, $item );

            # Get the subject line and add it to our cache for later, make sure we
            # strip any newlines so we can store it in the IMAP message properly
            # as well as any extra spaces
            $subject = __ConvertToText( $item->title() );
            $subject =~ s/\n//g;
            $subject = RLCommon::StrTrim( $subject );
            RLDebug::OutputDebug( 2, "RSS Item Subject = $subject" );
            push @subject_lines, $subject;

            # Retreive the date from the item or feed for future work.
            my $rss_date = __GetDate ($rss, $item);
            RLDebug::OutputDebug( 2, "RSS Item date = $rss_date" );

            # Convert the above date to a unix time code
            my $rss_time = HTTP::Date::str2time( $rss_date );
            RLDebug::OutputDebug( 2, "RSS Item unix timestamp = $rss_time" );

            # if expire enabled, get lastest-modified time of rss.
            if( $site_config->{expire} > 0 )
                {
                # really expired?
                if( time() - $rss_time > $site_config->{expire} * 60 * 60 * 24 )
                    {
                    next;
                    };
                }

            # Check to see if the rss item is older than the last update, in otherwords, the user
            # deleted it so we shouldn't add it back in.   There can be cases where the pubdate
            # provided in the rss feed on new items older than the last update so the
            # 'ignore-dates' is provided to override this behaviour.
            RLDebug::OutputDebug( 2, "Is '$rss_time' > '" . $site_config->{'last-updated'} . "' ?" );
            RLDebug::OutputDebug( 2, "Or is '$rss_date' = '' ?" );
            RLDebug::OutputDebug( 2, "Ignore the item date?: $site_config->{'ignore-dates'}" );
            if( $rss_time > $site_config->{'last-updated'} || $rss_date eq "" || $site_config->{'ignore-dates'} eq "yes" )
                {
                # message id is "rss url@host" AND x-rss-aggregator field is "Rigel"
                # and not deleted.
                RLDebug::OutputDebug( 2, "imap search = NOT DELETED HEADER message-id \"$message_id\" HEADER x-rss-aggregator \"Rigel\"" );
                my @search = $IMAP_CONNECT->search( "NOT DELETED HEADER message-id \"$message_id\" HEADER x-rss-aggregator \"Rigel\"" );

                if( RLCommon::IsError() )
                    {
                    RLCommon::LogLine( "WARNING: $@\r\n" );
                    next;
                    }

                # if message not found, append it.
                RLDebug::OutputDebug( 2, "IMAP Search Result: @search" );
                if( @search == 0 )
                    {
                    RLDebug::OutputDebug( 2, "Use Subjects? " . $site_config->{'use-subjects'} );
                    if( $site_config->{'use-subjects'} eq 'yes' )
                        {
                        # if the subject check is enabled, validate the current subject line
                        # against the old subject lines, make sure we disable special chacters
                        # in the match with \Q and \E
                        if( $old_subject_glob !~ m/\Q$subject\E/ )
                            {
                            RLDebug::OutputDebug( 2, "Subject not found in glob, adding item!" );
                            push @append_items, $item;
                            }
                        }
                    else
                        {
                        RLDebug::OutputDebug( 2, "Search retruned no items, subject cache not used, adding item" );
                        push @append_items, $item;
                        }

                    }
                else
                    {
                    RLDebug::OutputDebug( 2, "rss_date: $rss_date" );
                    if( !$rss_date )
                        {
                        next ; # date field is not found, we ignore it.
                        }

                    RLDebug::OutputDebug( 2, "Found the article in the IMAP folder and we have a valid date." );

                    # get last-modified_date of IMAP search result.
                    my ( $latest, $lmsg ) = RLIMAP::GetLatestDate( $IMAP_CONNECT, \@search );
                    RLDebug::OutputDebug( 2, "latest date = $latest" );

                    # if rss date is newer and we haven't been told to ignore them, 
                    # delete the search result and re-add the rss item so that the
                    # updated message is stroed in the IMAP folder.
                    if( $rss_time > $latest && $site_config->{'ignore-dates'} eq "no" )
                        {
                        RLDebug::OutputDebug( 2, "updating items!" );
                        push @delete_mail, @search;
                        push @append_items, $item;
                        }
                    }
                }
            }

        # delete items, if sync functionality is enabled
        if( $site_config->{'sync'} eq "yes" )
            {
            RLDebug::OutputDebug( 2, "Sync mode enabled for this feed." );
            my %found = ();
            for my $item (@items)
                {
                $found{$item->link()} = 1;
                }

            my $link = $rss->{'Rigel:rss-link'};
            my @search = $IMAP_CONNECT->search( "HEADER x-rss-link \"$link\" HEADER x-rss-aggregator \"Rigel\"" );

            for my $msg (@search)
                {
                my $link2 = $IMAP_CONNECT->get_header( $msg, "x-rss-item-link" );

                # must trim spaces, bug of IMAP server?
                $link2 =~ s/^\s*//g; $link2 =~ s/\s*$//g;
                if( !$found{$link2} )
                    {
                    push @delete_mail, $msg;
                    }
                }
            }

        # Delete messages that were flagged, we didn't do it earlier as it would have
        # messed up the above loop
        foreach my $MessageToDelete (@delete_mail)
            {
            $IMAP_CONNECT->delete_message( $MessageToDelete );
            }

        # Expunge the folder to actually get rid of the messages we just deleted
        $IMAP_CONNECT->expunge( $folder );

        # Now we actually append the new items to the folder
        for my $item (@append_items)
            {
            __SendItem( $site_config, $folder, $rss, $item );
            }

        # Find out how many items we added and give the user some feedback about it
        my $ItemsUpdated = scalar( @append_items );
        if( $ItemsUpdated > 0 )
            {
            RLCommon::LogLine( "\tAdded $ItemsUpdated articles.\r\n" );
            }
        else
            {
            RLCommon::LogLine( "\tNo items found to add.\r\n" );
            }

        # If for some reason we don't have any items from the feed, we want to keep
        # the old list of subject lines, otherwise when we do the next update all items
        # will be added back in to the IMAP folder which is probably not want we
        # want to happen
        if( scalar( @subject_lines ) < 1 )
            {
            __SendLastUpdate( $rss, $ttl, \@old_subject_lines );
            }
        else
            {
            __SendLastUpdate( $rss, $ttl, \@subject_lines );
            }

        return;
        }

    #
    # This function does the grunt work of expiring feed items on the IMAP
    # server.
    #
    #     __ExpireFeed( $rss, $site )
    #
    # Where:
    #     $rss is the feed as a string
    #     $site is the site configuration array
    #
    sub __ExpireFeed
        {
        my $rss                = shift;
        my $site_config     = shift;
        my $expire             = $site_config->{expire} || -1;

        if( $expire <= 0 )
            {
            RLDebug::OutputDebug( 2, "Expire disabled for this feed." );
            return;
            }

        my $folder        = RLConfig::ApplyTemplate( $rss, undef, 1, $site_config->{folder} );
        my $expire_folder = RLConfig::ApplyTemplate( $rss, undef, 1, $site_config->{'expire-folder'} );
        $folder           = RLIMAP::GetRealFolderName( $folder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        $expire_folder    = RLIMAP::GetRealFolderName( $expire_folder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );

        RLDebug::OutputDebug( 2, "RSS Folder:" . $folder );
        RLDebug::OutputDebug( 2, "Expire Folder:" . $expire_folder );

        my $key = Mail::IMAPClient->Rfc2060_date( time() - $expire * 60 * 60 * 24 );

        my $query = (defined $site_config->{'expire-unseen'}) ? "SENTBEFORE $key" : "SEEN SENTBEFORE $key";
        $query .= " HEADER x-rss-aggregator \"Rigel\"";
        RLDebug::OutputDebug( 2, "Expire query:" . $query );

        RLIMAP::IMAPSelectFolder( $IMAP_CONNECT, $folder );
        my @search = $IMAP_CONNECT->search( $query );

        if( RLCommon::IsError() )
            {
            RLCommon::LogLine( "WARNING: $@\r\n" );
            return;
            }

        if( @search == 0 ) { return; }

        if( $site_config->{'expire-folder'} && $expire_folder )
            {
            RLIMAP::IMAPCreateFolder( $IMAP_CONNECT, $expire_folder );
            for my $msg (@search) {
                RLCommon::LogLine( "  moving: $msg -> $expire_folder\r\n" );
                $IMAP_CONNECT->move( $expire_folder, $msg );
                }
            }
        else
            {
            RLCommon::LogLine( "  deleting: [@search]\r\n" );
            $IMAP_CONNECT->delete_message( @search );
            }
        }

    #
    # This function stores the last update message on the IMAP server for
    # a feed
    #
    #     __SendLastUpdate( $rss, $ttl, $subjects )
    #
    # Where:
    #     $rss is the rss feed
    #     $ttl is the time to live for the feed
    #     $subjects is the new subject cache to store
    #
    sub __SendLastUpdate
        {
        my $rss           = shift;
        my $ttl           = shift;
        my $subject_lines = shift;

        my $message_id    = $rss->{'Rigel:message-id'};
        my $date          = $rss->{'Rigel:last-modified'};
        my $link          = $rss->{'Rigel:rss-link'};
        my $a_date        = scalar( localtime() );

        my $body =<<"BODY"
From: Rigel@
Subject: $link
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
Content-Base: $link
Message-Id: $message_id
Date: $date
User-Agent: Rigel $VERSION
X-RSS-Link: $link
X-RSS-Aggregator: Rigel-checker
X-RSS-Aggregate-Date: $a_date;
X-RSS-Last-Modified: $date
X-RSS-TTL: $ttl

Link: $link
Last-Modified: $date
Aggregate-Date: $a_date
TTL: $ttl

BODY
;
        my $subject;

        # Add the subject lines from the update so we can skip
        # these articles if required on the next update
        foreach $subject (@{$subject_lines})
            {
            $body = $body . $subject . "\r\n";
            }

        my $folder = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:lastmod}" );
        $folder = RLIMAP::GetRealFolderName( $folder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );

		# Check to make sure the IMAP connection is still active
		if( $IMAP_CONNECT->IsUnconnected() )
			{
			$IMAP_CONNECT->reconnect();
			}

        RLDebug::OutputDebug( 2, "last update folder: $folder" );
        $IMAP_CONNECT->select( $folder );
        my $uid = $IMAP_CONNECT->append_string( $folder, $body, "Seen" );

        # As we cannot count on the above append_string to actually mark the
        # messages as seen and $uid may or may not acutall contain the message
        # make sure they're marked as read
        RLIMAP::MarkFolderRead( $IMAP_CONNECT, $folder );
        }

    #
    # This function stores a single article on the IMAP server in the
    # appropriate format.
    #
    #     __SendItem( $site, $folder, $rss, $item )
    #
    # Where:
    #     $site is the site configuration array
    #     $folder is the IMAP folder to store the item in
    #     $rss is the feed
    #     $item is the item to store
    #
    sub __SendItem
        {
        my $site_config = shift;
        my $folder      = shift;
        my $rss         = shift;
        my $item        = shift;
        my $headers     = "";
        my $optheaders  = "";
        my $body        = "";
        my $message        = "";

		# Generate the message headers
        $headers = __GetHeaders( $site_config, $rss, $item );

        # Format the body and generate any addditional headers that are type dependent (like MHTMLLINK)
        ( $optheaders, $body ) = __GetBody( $site_config, $rss, $item );
        $headers .= $optheaders;

        # append the message together
        $message = $headers . "\r\n" . $body;

        # Encode the message
        utf8::encode( $message );  # uft8 flag off.

        # Store the new message on the IMAP server in the desired folder
        $IMAP_CONNECT->append_string( $folder, $message );
        }

    #
    # This function creates a header string for a mail message based upon the
    # contents of the rss item to store
    #
    #     __GetHeaders(  $site, $rss, $item )
    #
    # Where:
    #     $site is the site configuration array
    #     $rss is the feed
    #     $item is the item to store
    #
    sub __GetHeaders
        {
        my $site_config = shift;
        my $rss         = shift;
        my $item        = shift;

        my $date       = __GetDate( $rss, $item );
        my $rss_date   = __GetRSSDate( $rss, $item ) || "undef";

        my $subject    = $site_config->{subject};
        my $from       = $site_config->{from};
        my $to         = $site_config->{to};
        my $message_id = __GenerateMessageID( $rss, $item );

        $subject = RLConfig::ApplyTemplate( $rss, $item, undef, $subject );
        $from    = RLConfig::ApplyTemplate( $rss, $item, undef, $from );

        RLDebug::OutputDebug( 2, "Getting headers for item with subject: $subject" );

        my $mime_type;

        # Make sure that the subject line didn't get poluted with html from the
        # rss feed.
        $subject = __ConvertToText( $subject );

        # if line feed character include, some mailer make header broken.. :<
        $subject =~ s/\n//g;

        my $m_from    = RLUnicode::ToMIME( $from );
        my $m_subject = RLUnicode::ToMIME( $subject );
        my $m_to      = RLUnicode::ToMIME( $to );
        my $a_date    = scalar( localtime() );
        my $l_date    = $rss->{'Rigel:last-modified'} || $a_date;
        my $link      = $rss->{'Rigel:rss-link'} || "undef";

        my $return_headers =<<"BODY"
From: $m_from
Subject: $m_subject
To: $m_to
Message-Id: $message_id
Date: $date
User-Agent: Rigel $VERSION
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


    #
    # This function returns the formated body of an rss item's
    # conetents, whether linked or contained
    #
    #     __GetBody( $site, $rss, $item )
    #
    # Where:
    #     $site is the site configuration array
    #     $rss is the feed
    #     $item is the item to store
    #
    sub __GetBody
        {
        my $site_config = shift;
        my $rss         = shift;
        my $item        = shift;
        my $headers     = "";
        my $body        = "";
        my $subject     = $site_config->{subject};
        my $from        = $site_config->{from};
        my $desc        = $item->description();
        my $link        = $item->link();
        my $mime_type   = "text/html";

        $subject = RLConfig::ApplyTemplate( $rss, $item, undef, $subject );
        $from    = RLConfig::ApplyTemplate( $rss, $item, undef, $from );

        # By default, use basic MIME headers, these can be replaced later on
        # by the specific delivery mode if required.
        if( $site_config->{'body-process'} eq 'text' ) { $mime_type = 'text/plain'; }
            
        $headers =<<"BODY"
MIME-Version: 1.0
Content-Type: $mime_type; charset="UTF-8"
Content-Transfer-Encoding: 8bit
Content-Base: $link
BODY
;

        # First, retreive the content, if we're following the link, use GetHTML, 
        # otherwise it's just the description from the feed.
        RLDebug::OutputDebug( 2, "Body source: " . $site_config->{'body-source'} );

        if( $site_config->{'body-source'} eq 'webpage' )
            {
            # If we getting a webpage, then we need to apply the template items to the
            # link as $item->link() is generated from the config message when we create
            # the "fake" rss feed for the website.
            my $reallink = RLConfig::ApplyTemplate( undef, undef, 1, $item->link() );
            
            $body = RLMHTML::GetHTML( $reallink, $site_config->{'user-agent'} );
            }
        elsif( $site_config->{'body-source'} eq 'link' )
            {
            $body = RLMHTML::GetHTML( $item->link(), $site_config->{'user-agent'} );
            }
        else
            {
            $body = $desc;
            }
        
        # Execute the first cropping action as defined in the site config
        RLDebug::OutputDebug( 2, "Pre-cropping the body" );
        $body = RLMHTML::CropBody( $body, $site_config->{'pre-crop-start'}, $site_config->{'pre-crop-end'} );

        # Some feeds use relative url's instead of absolute, it's a little processor
        # intensive to convert them so unless the feed needs it, it's not done by
        # default.
        if( $site_config->{'absolute-urls'} eq 'yes' )
            {
            RLDebug::OutputDebug( 2, "Converting relative URL's to Absolute" );
            $body = RLMHTML::MakeLinksAbsolute( $body, $item->link() );
            }

        # Time to convert the body to it's final type, the default is to leave it alone.
        if( $site_config->{'body-process'} eq 'text' )
            {
            # HTML::FormatText::WithLinks::AndTables is a little flaky, eval it so things don't blow up.
            RLDebug::OutputDebug( 2, "Converting body to text" );
            eval { $body = HTML::FormatText::WithLinks::AndTables->convert( $body ); };
             }
        elsif( $site_config->{'body-process'} eq 'mhtml' )
            {
            # Call the MHTML code, since we've already retreived the body and 
            # cropped it, there's no need to pass cropping or useragent to 
            # GetMHTML and we will pass the existing body in as the last arg.
            RLDebug::OutputDebug( 2, "Converting body to MHTML" );
            $body = RLMHTML::GetMHTML( $item->link(), '', '', '', $body );

            # The MHTML code returns both headers and the body in a single 
            # string, we need to split them up
            ( $headers, $body ) = split( /\r\n\r\n/, $body, 2 );
            }
            
        # Execute the second cropping action as defined in the site config
        RLDebug::OutputDebug( 2, "Post-cropping the body" );
        $body = RLMHTML::CropBody( $body, $site_config->{'post-crop-start'}, $site_config->{'post-crop-end'} );

		# Add the link to the top of the message body.
        if( $site_config->{'body-process'} eq 'text' )
			{
			$body = "Article Link: " . $item->link() . "\r\n\r\n" . $body;
			}
		else
			{
			$body = "Article Link: <a href='" . $item->link() . "'>" . $item->link() . "</a><br><br>\r\n\r\n" . $body;
			}
		
        return ($headers, $body);
        }

    #
    # This function converts an rss item with HTML markup in it to plain text
    #
    #     __ConvertToText( $string )
    #
    # Where:
    #     $string is the string to convert
    #
    sub __ConvertToText
        {
        my $string = shift;

        if ( !$string ) { return "" };

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

        while( $string =~ /($text_regex)($tag_regex)?/gso )
            {
            if( $1 eq '' and $2 eq '') { last; }

            $result .= $1;
            my $tag_tmp = $2;

            if( $tag_tmp =~ /^<(XMP|PLAINTEXT|SCRIPT)(?![0-9A-Za-z])/i )
                {
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

    #
    # This function creates a message id to be used in the IMAP messages
    #
    #     __GenerateMessageID( $rss, $item )
    #
    # Where:
    #     $rss is the feed (unused)
    #     $item is the feed item
    #
    sub __GenerateMessageID
        {
        my $rss  = shift;
        my $item = shift;

        return sprintf( '%s@%s', RLCommon::StrTrim( $item->link() ), $GLOBAL_CONFIG->{host} );
        }

    #
    # This function returns the last modified date for an rss item
    #
    #     __GetRSSDate( $rss, $item )
    #
    # Where:
    #     $rss is the feed (unused)
    #     $item is the feed item
    #
    sub __GetRSSDate
        {
        my $rss  = shift;
        my $item = shift;

        # priority of rss last-modified-date is ...
        # 1. item -> 2. channel -> 3. http header.
        # http header is the last resort!
        #
        # dc:date is derived from rss 1.0 specification
        # pubDate, lastbuilddate are derived from rss 0.91 rev 3, rss 2.0
        #
        return $item->pubDate() || $rss->pubDate() || undef;
        }

    #
    # This function returns a HTTP formated time for an rss item
    #
    #     __GetDate( $rss, $item )
    #
    # Where:
    #     $rss is the feed (unused)
    #     $item is the feed item
    #
    sub __GetDate
        {
        my $rss  = shift;
        my $item = shift;
        my $date = __GetRSSDate( $rss, $item ) || "";

        return HTTP::Date::time2str(HTTP::Date::str2time( $date ) );
        }

    #
    # This function returns an array of feed site configurations from the
    # IMAP server
    #
    #     __GetFeedsFromIMAP()
    #
    sub __GetFeedsFromIMAP
        {
        my $message;
        my $feedconf;
        my $feeddesc;
        my $e;
        my @messages;
        my @config_list;
        my %config;
        my $folder = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:manage}%{dir:sep}Configuration" );
        my $mp       = new MIME::Parser;

        # setup the message parser so we don't get any errors and we
        # automatically decode messages
        $mp->ignore_errors( 1 );
        $mp->extract_uuencode( 1 );

        $folder = RLIMAP::GetRealFolderName( $folder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "config folder: $folder" );
        $IMAP_CONNECT->select( $folder );

        my $show_v1_alert = 0;
        
        @messages = $IMAP_CONNECT->messages();

        foreach $message (@messages)
            {
            my $ua = $IMAP_CONNECT->get_header( $message, 'User-Agent' );
            
            # Retreive the complete message and run it through the MIME parser
            eval { $e = $mp->parse_data( $IMAP_CONNECT->message_string( $message ) ); };
            my $error = ($@ || $mp->last_error);

            if( $error )
                {
                $feedconf = "";
                }
            else
                {
                # get_mime_text_body will retrevie all the plain text peices of the
                # message and return it as one string.
                $feedconf = RLCommon::StrTrim( __GetMIMETextBody( $e ) );
                $feeddesc = $IMAP_CONNECT->subject( $message );
                $mp->filer->purge;
                }

            # parse the configuration options in to a configuration object
            %config = RLConfig::ParseConfigString( $feedconf, $feeddesc );

            # check to see if the config message is from Rigel V1, if so, convert to the new
            # format and alert the user to run a config refresh.
            if( $ua =~ m/Rigel version .1/gi )
                {
                $show_v1_alert = 1;
                
                ( $config{'body-source'}, 
                  $config{'pre-crop-start'}, 
                  $config{'pre-crop-end'}, 
                  $config{'body-process'}, 
                  $config{'post-crop-start'}, 
                  $config{'post-crop-end'} ) = __ConvertV1toV2( $config{'delivery-mode'}, 
                                                                  $config{'crop-start'}, 
                                                                  $config{'crop-end'} );
                }

            # If the only-one-feed option has not been enabled, or it has and this is the
            # feed to use, then add it to the config list.
            if( $GLOBAL_CONFIG->{'only-one'} eq undef || $GLOBAL_CONFIG->{'only-one'} eq $feeddesc )
                {
                push @config_list, { %config };
                }
            }

        if( $show_v1_alert > 0 && $GLOBAL_CONFIG->{'config-update'} == 0 )
            {
            RLCommon::LogLine( "Found Rigel Version 1 configuration message(s), please backup your configuration and then run \"perl Rigel -o -R\" to refresh the configuration messages.\r\n" );
            }
            
        return \@config_list;
        }

    #
    # This function converts the old version 1 configruation information in
    # to the new version 2 standard.  This function will be removed when 
    # version 3 is released.
    #
    #     __ConvertV1toV2( $delivery_type, $crop_start, $crop_end )
    #
    # Where:
    #     $delivery_type is the old delivery-mode value and is one of embedded,
    #                     raw, text, mhtmllink, htmllink, textlink, thtmllink 
    #     $crop_start is the old crop-start value
    #     $crop_end is the old crop-end value
    #
    sub __ConvertV1toV2()
        {
        my $type        = shift;
        my $crop_start = shift;
        my $crop_end   = shift;
        my $source       = "";
        my $pre_start  = "";
        my $pre_end    = "";
        my $process    = "";
        my $post_start = "";
        my $post_end   = "";
        
        if( $type eq 'embedded' )
            {
            $source     = "link";
            $pre_start  = $crop_start;
            $pre_end    = $crop_end;
            $process    = "none";
            }
        elsif( $type eq 'text' )
           {
            $source     = "feed";
            $process    = "text";
            $post_start  = $crop_start;
            $post_end    = $crop_end;
            }
        elsif( $type eq 'mhtmllink' )
            {
            $source     = "link";
            $pre_start  = $crop_start;
            $pre_end    = $crop_end;
            $process    = "mhtml";
            }
        elsif( $type eq 'htmllink' )
            {
            $source     = "link";
            $pre_start  = $crop_start;
            $pre_end    = $crop_end;
            $process    = "none";
            }
        elsif( $type eq 'textlink' )
            {
            $source     = "link";
            $process    = "text";
            $post_start  = $crop_start;
            $post_end    = $crop_end;
            }
        elsif( $type eq 'thtmllink' )
            {
            $source     = "link";
            $pre_start  = $crop_start;
            $pre_end    = $crop_end;
            $process    = "text";
            }
        else
            {
            $source     = "feed";
            $pre_start  = $crop_start;
            $pre_end    = $crop_end;
            $process    = "none";
            }

        return ( $source, $pre_start, $pre_end, $process, $post_start, $post_end );
        }
        
    #
    # This function returns the textual version of the message body in a
    # MIME message
    #
    #     __GetMIMETextBody( $mime )
    #
    # Where:
    #     $mime is the mime encoded message to retreive
    #
    sub __GetMIMETextBody
        {
        my $ent = shift;

        my $text;
        my $wd;

        if( my @parts = $ent->parts )
            {
            return __GetMIMETextBody( $_ ) for @parts;
            }
        elsif( my $body = $ent->bodyhandle )
            {
            my $type = $ent->head->mime_type;

            if( $type eq 'text/plain' )
                {
                if( $ent->head->get( 'Content-Type' ) and $ent->head->get( 'Content-Type' ) =~ m!charset="([^\"]+)"! )
                    {
                    $wd = supported MIME::WordDecoder( uc( $1 ) );
                    }

                if( !$wd )
                    {
                    $wd = supported MIME::WordDecoder "ISO-8859-1";
                    }

                return $text .  RLUnicode::ToUTF8( $wd->decode( $body->as_string || '' ) );
                }
            }
        }

    #
    # This function processes and add/delete messages on the IMAP server
    #
    #     __ProcessChangeRequests()
    #
    sub __ProcessChangeRequests
        {
        my $site_config = RLConfig::GetSiteConfig();
        my @messages;
        my $message;
        my $feedconf;
        my @config_list;
        my %config;
        my $siteurl;
        my $uid;
        my $AddFolder     = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:manage}%{dir:sep}Add" );
        my $DeleteFolder  = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:manage}%{dir:sep}Delete" );
        my $ConfigFolder  = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:manage}%{dir:sep}Configuration" );
        my $LastModFolder = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:lastmod}" );
        my $e;
        my $mp              = new MIME::Parser;

        # setup the message parser so we don't get any errors and we
        # automatically decode messages
        $mp->ignore_errors( 1 );
        $mp->extract_uuencode( 1 );

        $AddFolder = RLIMAP::GetRealFolderName( $AddFolder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "Add folder: $AddFolder" );
        RLIMAP::IMAPCreateFolder( $IMAP_CONNECT, $AddFolder );

        $DeleteFolder = RLIMAP::GetRealFolderName( $DeleteFolder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "Delete folder: $DeleteFolder" );
        RLIMAP::IMAPCreateFolder( $IMAP_CONNECT, $DeleteFolder );

        $ConfigFolder = RLIMAP::GetRealFolderName( $ConfigFolder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "Config folder: $ConfigFolder" );
        RLIMAP::IMAPCreateFolder( $IMAP_CONNECT, $ConfigFolder );

        $LastModFolder = RLIMAP::GetRealFolderName( $LastModFolder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "last update folder: $LastModFolder" );
        RLIMAP::IMAPCreateFolder( $IMAP_CONNECT, $LastModFolder );

        $IMAP_CONNECT->select( $AddFolder );
        @messages = $IMAP_CONNECT->messages();

        foreach $message (@messages)
            {
            # Retreive the complete message and run it through the MIME parser
            eval { $e = $mp->parse_data( $IMAP_CONNECT->message_string( $message) ); };
            my $error = ($@ || $mp->last_error);

            my $feeddesc = $IMAP_CONNECT->subject( $message );

            $feedconf = "";
            $feedconf = RLCommon::StrTrim( __GetMIMETextBody( $e ) );
            $mp->filer->purge;

            %config = RLConfig::ParseConfigString( $feedconf );

            $siteurl = $config{url};
            $siteurl = RLCommon::StrTrim( $siteurl );

            if( $feeddesc eq "" ) { $feeddesc = $siteurl; }

            if ($siteurl ne "http://template")
                {
                my $headers =<<"BODY"
From: Rigel@
Subject: $feeddesc
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
User-Agent: Rigel $VERSION
BODY
;
                RLCommon::LogLine( "Adding feed: " . $siteurl . "\r\n" );

                $IMAP_CONNECT->append_string( $ConfigFolder, $headers . "\n" . $feedconf, "Seen" );
                $IMAP_CONNECT->delete_message( $message );
                }

            # If we're updating the configuration messages, delete all the add messages
            # as well to ensure the templates are up to date.
            if( $GLOBAL_CONFIG->{'config-update'} )
                {
                $IMAP_CONNECT->delete_message( $message );
                }
            }

        # You can't change the folder during the above loop or the return
        # from messages() becomes invalid, so loop thorugh all the messages
        # in the config folder and mark them all as read

        # As we cannot count on the above addpend_string to actually mark the
        # messages as seen and $uid may or may not acutall contain the message
        # make sure they're marked as read
        RLIMAP::MarkFolderRead( $IMAP_CONNECT, $ConfigFolder );

        # Now expunge any deleted messages
        $IMAP_CONNECT->select( $AddFolder );
        $IMAP_CONNECT->expunge( $AddFolder );  # For some reason the folder has to be passed here otherwise the expunge fails

        # Now fill in any extra template messages we need
        $site_config->{'desc'} = "Template feed";
        $site_config->{'url'}  = "http://template";
        my $template_message   = RLTemplates::NewFeed( $VERSION, $site_config );

        my $i = 10 - $IMAP_CONNECT->message_count( $AddFolder );
        for( ; $i != 0; $i-- )
            {
            $uid = $IMAP_CONNECT->append_string( $AddFolder, $template_message, "Seen" );
            }

        # As we cannot count on the above addpend_string to actually mark the
        # messages as seen and $uid may or may not acutall contain the message
        # make sure they're marked as read
        RLIMAP::MarkFolderRead( $IMAP_CONNECT, $AddFolder );

        $IMAP_CONNECT->select( $DeleteFolder );
        @messages = $IMAP_CONNECT->messages();

        my $Subject;
        my $message_id;
        my @search;
        my $modified;
        my @FeedsToDelete;

        foreach $message (@messages)
            {
            push @FeedsToDelete, $IMAP_CONNECT->subject( $message );
            $IMAP_CONNECT->delete_message( $message );
            $IMAP_CONNECT->expunge( $DeleteFolder );
            }

        $IMAP_CONNECT->select( $LastModFolder );
        foreach $Subject (@FeedsToDelete)
            {
            RLCommon::LogLine( "Deleting feed: " . $Subject . "\r\n" );
            $message_id = sprintf( '%s@%s', $Subject, $GLOBAL_CONFIG->{host} );
            @search = $IMAP_CONNECT->search( "UNDELETED HEADER message-id \"$message_id\" HEADER x-rss-aggregator \"Rigel-checker\"" );

            foreach $modified (@search)
                {
                $IMAP_CONNECT->delete_message( $modified );
                $IMAP_CONNECT->expunge();
                }
            }

        return;
        }

    #
    # This function checks the help folder and updates messages
    # as required.
    #
    #     __VerifyHelp()
    #
    sub __VerifyHelp
        {
        my $site_config = RLConfig::GetSiteConfig();
        my @messages;
        my $HelpFolder  = RLConfig::ApplyTemplate( undef, undef, 1, "%{dir:manage}%{dir:sep}Help" );

        $HelpFolder = RLIMAP::GetRealFolderName( $HelpFolder, $GLOBAL_CONFIG->{'directory_separator'}, $GLOBAL_CONFIG->{'prefix'} );
        RLDebug::OutputDebug( 2, "Help folder: $HelpFolder" );
        RLIMAP::IMAPCreateFolder( $IMAP_CONNECT, $HelpFolder );

        $IMAP_CONNECT->select( $HelpFolder );
        @messages = $IMAP_CONNECT->messages();

        # If we're updating the configuration messages, delete all the help messages
        # as well to ensure the templates are up to date.
        if( $GLOBAL_CONFIG->{'config-update'} )
            {
            my $message;
            
            foreach $message (@messages)
                {
                $IMAP_CONNECT->delete_message( $message );
                }
            
            $IMAP_CONNECT->select( $HelpFolder );
            $IMAP_CONNECT->expunge( $HelpFolder );  # For some reason the folder has to be passed here otherwise the expunge fails
            
            @messages = $IMAP_CONNECT->messages();
            }
        
        # If the help folder is empty, append the help message and samples
        if( scalar( @messages ) == 0 )
            {
            RLDebug::OutputDebug( 2, "Creating help messages..." );
            my $message = "";
            my @samples = RLTemplates::FeedSampleList();
            my $sample = "";

            # Add the samples first so that the help message show at the top
            # of the list of messagse as most mail readers will sort by received
            # date.
            foreach $sample (@samples)
                {
                $message = RLTemplates::FeedSample( $VERSION, $site_config, $sample );
                $IMAP_CONNECT->append_string( $HelpFolder, $message, "Seen" );
                }

            $message = RLTemplates::Help( $VERSION, $site_config );
            $IMAP_CONNECT->append_string( $HelpFolder, $message, "Seen" );

            # As we cannot count on the above addpend_string to actually mark the
            # messages as seen and $uid may or may not acutall contain the message
            # make sure they're marked as read
            RLIMAP::MarkFolderRead( $IMAP_CONNECT, $HelpFolder );
            }

        return;
        }

    #
    # This function 'fixes' some common feeds errors
    #
    #     __FixFeed( $feed )
    #
    # Where:
    #     $feed is the raw feed to fix
    #
    sub __FixFeed
        {
        my $content  = shift;

        my $fixed;
        my $count;

        # First, strip any spaces from feed
        $fixed = RLCommon::StrTrim( $content );

        # Some feeds seem to have some crap charaters in them (either at the begining or the end)
        # which need to get stripped out, so build a hash that contains the ASCII values of all the
        # characters we want to keep (\r, \n, a-Z, etc.).  Then run a regex to process the change.
        RLDebug::OutputDebug( 2, "Remove unwanted characters..." );
        #    my %CharatersToKeep = map {$_=>1} (9,10,13,32..127);
        #    $fixed =~ s/(.)/$CharatersToKeep{ord($1)} ? $1 : ' '/eg;
        $fixed =~ s/[^[:ascii:]]/ /eg;
        RLDebug::OutputDebug( 2, "Finished." );

        # if the opening xml tag is missing, add it
        $count = 0;
        RLDebug::OutputDebug( 2, "Add missing XML tag..." );

        while( $fixed =~ /\<\?xml/gi )
            {
            $count++;
            }

        if( $count == 0  )
            {
            $fixed = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" . $fixed;
            }

        # Make sure we don't have duplicate closing channel tags
        $count = 0;
        RLDebug::OutputDebug( 2, "Remove duplicate closing channel tags..." );
        while( $fixed =~ /\<\/channel\>/gi )
            {
            $count++;
            }

        if( $count > 1 )
            {
            for( my $i = 1; $i < $count; $i++ )
                {
                    $fixed =~ s/\<\/channel\>//i;
                }
            }

        # Make sure we don't have duplicate closing rss tags
        $count = 0;
        RLDebug::OutputDebug( 2, "Remove duplicate closing rss tags..." );
        while( $fixed =~ /\<\/rss\>/gi )
            {
            $count++;
            }

        if ( $count > 1  )
            {
            for( my $i = 1; $i < $count; $i++ )
                {
                $fixed =~ s/\<\/rss\>//i;
                }
            }

        return $fixed;
        }

    #
    # This function 'creates' a feed based upon a web page.
    #
    #     __CreateRSSFeed( $link )
    #
    # Where:
    #     $link is the URL of the web site
    #
    sub __CreateRSSFeed
        {
        my $link = shift;
        
        my $pubDate = HTTP::Date::time2str();
        my $title = "Website: " . $link;
        
        my $feed = XML::FeedPP::RSS->new();

        $feed->title( $title );
        $feed->link( $link );
        $feed->pubDate( $pubDate );
        
        my $item =$feed->add_item();
        $item->title( $title );
        $item->link( $link );
        $item->pubDate( $pubDate );

        return $feed->to_string();
        }
    }


1;
