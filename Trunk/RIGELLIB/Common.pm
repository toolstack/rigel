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
# This is the common functions module for Rigel, it is
# responsible for:
#     - Retreiving the RSS feed
#     - Retreiving the username/password info if required
#

package RIGELLIB::Common;
{
    use strict;
    use RIGELLIB::Config;
    use RIGELLIB::UserAgent;
    use RIGELLIB::Unicode;
    use RIGELLIB::Debug;
    use Data::Dumper;

    our $config = undef;
    our $debug = undef;

    sub new {
        my $pkg_name = shift;

        $config = RIGELLIB::Config->new()->get_global_configall();

	$debug = RIGELLIB::Debug->new( \%{$config} );

        bless {}, $pkg_name;
    }

    sub getrss_and_response {
        my $this        = shift;
        my $uri         = shift;
        my $headers     = shift;
        my %header_hash = %{$headers};
        my $ua          = RIGELLIB::UserAgent->new();

        if( $debug->DebugEnabled() ) {
            $debug->OutputDebug( "getrss_and_response Proxy Dump:\n" . Data::Dumper::Dumper( $config->{'proxy'} ) );
        }

	$ua->proxy(['http','ftp'], $config->{'proxy'}) if($config->{'proxy'});
        my $request = HTTP::Request->new('GET');
        $request->url($uri);

        # set header if any.
        while (my ($key,$value) = each %header_hash) {
            $request->header( $key => $value );
        }

        # finally send request.
        my $response = $ua->request($request);

        $debug->OutputDebug( "getrss_and_response response code :" . $response->code );

        my @rss_and_response = ();

        # Not Modified
        if ($response->code eq '304') {
            return @rss_and_response;
        }

        # Connection Error.
        unless ($response->is_success) {
            return @rss_and_response;
        }

        # RSS Get Succeeded.
        my $content = $response->content;
        my $header = substr ($content, 0, 100);

        # force all contents to UTF-8
        if ($header =~ /encoding="([^<>]*?)"/i) {
            $content = RIGELLIB::Unicode::to_utf8($content,$1);
        }

        $content =~ s/<\?xml.*?\?>/<\?xml version="1.0" encoding="utf-8"\?>/;
        # convert HTML Numeric reference to UTF-8 Character
        $content =~ s/\&#(x)?([a-f0-9]{1,5});/
 			my $tmpstr = ($1)
                                   ? pack( "H*", sprintf( "%08s", "$2" ) )
                                   : pack( "N*", $2 );
                        Encode::encode( "UTF-8",
                            Encode::decode( "UTF-32BE", $tmpstr )
                        );
                    /eig;
 
	push @rss_and_response, $content;
        push @rss_and_response, $response;

        return @rss_and_response;
    }


    sub getUser {
        my $this    = shift;
        my $prompt  = shift;
        my $isproxy = shift;

	$prompt = "UserName :" unless(defined $prompt);

        if ($isproxy && defined $config->{'proxy-user'}) {
            return $config->{'proxy-user'};
        }

        # prompt and get username
        print $prompt;
        my $user = <STDIN>;
        chomp($user);
        $user = undef unless length $user;

        if (!defined $config->{'proxy-user'} && $isproxy) {
            # add username to @ARGV
            push @ARGV, "--proxy-user";
            push @ARGV, $user;
        }

        return $user;
    }


    sub getPass {
        my $this    = shift;
        my $prompt  = shift;
        my $isproxy = shift;

	$prompt = "Password: " unless(defined $prompt);

        if ($isproxy && defined $config->{'proxy-pass'}) {
            return $config->{'proxy-pass'};
        }

        print $prompt;
        my $password = undef;
        if( $^O =~ /Win32/ ) {
            eval 'use Term::Getch';
            if( $@ ) {
                print "Term::Getch is not installed, can not continue!\n";
                die;
            } else {
                my @c = ();
                my $tmp;
                do {
                    $tmp = getch();
                    push @c, $tmp if $tmp and $tmp =~ /\w/;
                } while not $tmp or $tmp ne "\r";
                $password = join('' => @c);
            }
            print "\n";

        } else {
            system("stty -echo");
            $password = <STDIN>;
            system("stty echo");
            print "\n";  # because we disabled echo
        }
        chomp($password);
        $password = undef unless length $password;

        if (!defined $config->{'proxy-pass'} && $isproxy) {
            # add password to @ARGV
            push @ARGV, "--proxy-pass";
            push @ARGV, $password;
        }

        return $password;
    }


    # wrapper of proxy password getter
    sub getProxyPass_ifEnabled {
        my $this = shift;

        if ($config->{'proxy'} && $config->{'proxy-user'}) {
            $this->getPass( 'proxy password: ', 1 );
        }
    }
}

1;
