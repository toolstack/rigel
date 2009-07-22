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

package Common;
    {
    use strict;
    use RIGELLIB::UserAgent;
    use RIGELLIB::Unicode;
    use Debug;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA=qw(Exporter);
    @EXPORT_OK=qw(SetCommonConfig getrss_and_response getUser getPass getProxyPass_ifEnabled str_trim);

    our %config = undef;

    sub SetCommonConfig
        {
        (%config) = %{(shift)};
        }

    #
    # This function returns an array with two entires, the rss feed as a
    # string and the response code from the HTTP connection.
    #
    #     RIGELLIB::Common->getrss_and_response(  $URL,  $headers, $ttl  )
    #
    # Where:
    #     $URL is the url of the feed to retreive
    #     $headers are any headers to add to the HTTP request
    #     $ttl is unused at this time
    #
    sub getrss_and_response
        {
        my $uri              = shift;
        my $headers          = shift;
        my $rss_ttl          = shift;
        my %header_hash      = %{$headers};
        my $ua               = RIGELLIB::UserAgent->new( \%config );
        my @rss_and_response = ();

        Debug::OutputDebug( 2, "Proxy Dump = ", %config->{'proxy'} );

        if( %config->{'proxy'} )
            {
            $ua->proxy( ['http','ftp'], %config->{'proxy'} );
            }

        my $request = HTTP::Request->new( 'GET' );

        Debug::OutputDebug( 1, "uri = " . $uri );
        $request->url( $uri );

        # set header if any.
        while( my ($key,$value) = each %header_hash )
            {
            Debug::OutputDebug( 1, "Header[$key] = $value" );
            $request->header( $key => $value );
            }

        # finally send request.
        my $response = $ua->request( $request );

        Debug::OutputDebug( 1, "response code :" . $response->code );

        # Not Modified
        if( $response->code eq '304' )
            {
            Debug::OutputDebug( 1, "received 304 code from RSS Server, not modified" );

            return @rss_and_response;
            }

        # Connection Error.
        unless( $response->is_success )
            {
            Debug::OutputDebug( 1, "connection error" );

            return @rss_and_response;
            }

        # RSS Get Succeeded.
        my $content = $response->content;
        my $header = substr( $content, 0, 100 );

        # force all contents to UTF-8
        if( $header =~ /encoding="([^<>]*?)"/i )
            {
            $content = RIGELLIB::Unicode::to_utf8( $content, $1 );
            }

        # Replace the opening xml tag if it does not have the version/encoding in it
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

        Debug::OutputDebug( 2, "content = $content" );
        Debug::OutputDebug( 2, "response = $response" );

        push @rss_and_response, $content;
        push @rss_and_response, $response;

        return @rss_and_response;
        }

    #
    # This function interactivly prompts (if required) for a username and
    # returns it.
    #
    #     RIGELLIB::Common->getUser(  $prompt,  $is_proxy  )
    #
    # Where:
    #     $prompt is the text to display before the user enters data
    #     $is_proxy defines if this is for the proxy server or not (t/f)
    #
    sub getUser
        {
        my $prompt  = shift;
        my $isproxy = shift;

        if( !defined( $prompt ) )
            {
            $prompt = "UserName: ";
            }

        if( $isproxy && defined %config->{'proxy-user'} )
            {
            return %config->{'proxy-user'};
            }

        # prompt and get username
        print $prompt;
        my $user = <STDIN>;
        chomp( $user );
        $user = undef unless length $user;

        if( !defined %config->{'proxy-user'} && $isproxy )
            {
            # add username to @ARGV
            push @ARGV, "--proxy-user";
            push @ARGV, $user;
            }

        return $user;
        }

    #
    # This function interactivly prompts (if required) for a password and
    # returns it.
    #
    #     RIGELLIB::Common->getPass(  $prompt,  $is_proxy  )
    #
    # Where:
    #     $prompt is the text to display before the user enters data
    #     $is_proxy defines if this is for the proxy server or not (t/f)
    #
    sub getPass
        {
        my $prompt  = shift;
        my $isproxy = shift;

        if( !defined( $prompt ) )
            {
            $prompt = "Password: ";
            }

        if( $isproxy && defined %config->{'proxy-pass'} )
            {
            return %config->{'proxy-pass'};
            }

        print $prompt;
        my $password = undef;
        if( $^O =~ /Win32/ )
            {
            eval 'use Term::Getch';
            if( $@ )
                {
                print "Term::Getch is not installed, can not continue!\n";
                die;
                }
            else
                {
                my @c = ();
                my $tmp;
                do
                    {
                    $tmp = getch();
                    push @c, $tmp if $tmp and $tmp =~ /\w/;
                    } while not $tmp or $tmp ne "\r";

                $password = join( '' => @c );
                }

            print "\n";
            }
        else
            {
            system( "stty -echo" );
            $password = <STDIN>;
            system( "stty echo" );
            print "\n";  # because we disabled echo
            }

        chomp( $password );
        $password = undef unless length $password;

        if( !defined %config->{'proxy-pass'} && $isproxy )
            {
            # add password to @ARGV
            push @ARGV, "--proxy-pass";
            push @ARGV, $password;
            }

        return $password;
        }

    #
    # This function interactivly prompts (if required) for a username and
    # returns it for the proxy server.
    #
    #     RIGELLIB::Common->getProxyPass_ifEnabled(  )
    #
    sub getProxyPass_ifEnabled
        {

        if( %config->{'proxy'} && %config->{'proxy-user'} )
            {
            getPass( 'proxy password: ', 1 );
            }
        }

    #
    # This function trims leading/trailing spaces from a string.
    #
    #     RIGELLIB::Common->str_trim( $string )
    #
    # Where:
    #     $string is the string to trim
    #
    sub str_trim
        {
        my $str     = shift;

        if( !defined( $str ) )
            {
            return undef;
            }

        chomp $str;
        $str =~ s/^\s*//;
        $str =~ s/\s*$//;

        return $str;
        }
    }

1;
