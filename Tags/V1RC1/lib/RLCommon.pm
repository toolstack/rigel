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

package RLCommon;
    {
    use strict;
    use RLUserAgent;
    use RLUnicode;
    use RLDebug;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(SetCommonConfig GetRSS GetUser GetPass GetProxyPass StrTrim IsError LogLine RotateLog GetLogFileHandle);

    our %config  = undef;
    our $LogFH   = undef;

    sub SetCommonConfig
        {
        (%config) = %{(shift)};

        my $filename = RLConfig::ApplyTemplate( undef, undef, undef, %config->{'log-file'} );

        if( %config->{'log-file'} )
            {
            if( %config->{'log-rotate'} eq "append" )
                {
                open( $LogFH, ">>" . $filename );
                }
            elsif( %config->{'log-rotate'} eq "unique" )
                {
                open( $LogFH, ">>" . $filename );
                }
            else
                {
                open( $LogFH, ">" . $filename );
                }
            }
        }

    #
    # This function rotates to the next log file name if unique logging is
    # enabled.
    #
    #     RLCommon::RotateLog( )
    #
    sub RotateLog
        {
        if( %config->{'log-rotate'} eq "unique" )
            {
            close( $LogFH );

            open( $LogFH, ">>" . RLConfig::ApplyTemplate( undef, undef, undef, %config->{'log-file'} ) );
            }

        return;
        }

    #
    # This function returns an array with two entires, the rss feed as a
    # string and the response code from the HTTP connection.
    #
    #     RLCommon::GetRSS(  $URL,  $headers, $ttl  )
    #
    # Where:
    #     $URL is the url of the feed to retreive
    #     $headers are any headers to add to the HTTP request
    #     $ttl is unused at this time
    #
    sub GetRSS
        {
        my $uri              = shift;
        my $headers          = shift;
        my $rss_ttl          = shift;
        my %header_hash      = %{$headers};
        my $ua               = RLUserAgent->new( \%config );
        my @rss_and_response = ();

        RLDebug::OutputDebug( 2, "Proxy Dump = ", %config->{'proxy'} );

        if( %config->{'proxy'} )
            {
            $ua->proxy( ['http','ftp'], %config->{'proxy'} );
            }

        my $request = HTTP::Request->new( 'GET' );

        RLDebug::OutputDebug( 1, "uri = " . $uri );
        $request->url( $uri );

        # set header if any.
        while( my ($key,$value) = each %header_hash )
            {
            RLDebug::OutputDebug( 1, "Header[$key] = $value" );
            $request->header( $key => $value );
            }

        # finally send request.
        my $response = $ua->request( $request );

        RLDebug::OutputDebug( 1, "response code :" . $response->code );

        # Not Modified
        if( $response->code eq '304' )
            {
            RLDebug::OutputDebug( 1, "received 304 code from RSS Server, not modified" );

            return @rss_and_response;
            }

        # Connection Error.
        unless( $response->is_success )
            {
            RLDebug::OutputDebug( 1, "connection error" );

            return @rss_and_response;
            }

        # RSS Get Succeeded.
        my $content = $response->content;
        my $header = substr( $content, 0, 100 );

        # force all contents to UTF-8
        if( $header =~ /encoding="([^<>]*?)"/i )
            {
            $content = RLUnicode::ToUTF8( $content, $1 );
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

        RLDebug::OutputDebug( 2, "content = $content" );
        RLDebug::OutputDebug( 2, "response = $response" );

        push @rss_and_response, $content;
        push @rss_and_response, $response;

        return @rss_and_response;
        }

    #
    # This function interactivly prompts (if required) for a username and
    # returns it.
    #
    #     RLCommon::GetUser(  $prompt,  $is_proxy  )
    #
    # Where:
    #     $prompt is the text to display before the user enters data
    #     $is_proxy defines if this is for the proxy server or not (t/f)
    #
    sub GetUser
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
        RLCommon::LogLine( $prompt );
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
    #     RLCommon::GetPass(  $prompt,  $is_proxy  )
    #
    # Where:
    #     $prompt is the text to display before the user enters data
    #     $is_proxy defines if this is for the proxy server or not (t/f)
    #
    sub GetPass
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

        RLCommon::LogLine( $prompt );
        my $password = undef;
        if( $^O =~ /Win32/ )
            {
            eval 'use Term::Getch';
            if( $@ )
                {
                RLCommon::LogLine( "Term::Getch is not installed, can not continue!\r\n" );
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

            RLCommon::LogLine( "\r\n" );
            }
        else
            {
            system( "stty -echo" );
            $password = <STDIN>;
            system( "stty echo" );
            RLCommon::LogLine( "\r\n" );  # because we disabled echo
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
    #     RLCommon::getProxyPass(  )
    #
    sub GetProxyPass
        {

        if( %config->{'proxy'} && %config->{'proxy-user'} )
            {
            GetPass( 'proxy password: ', 1 );
            }
        }

    #
    # This function trims leading/trailing spaces from a string.
    #
    #     RLCommon::StrTrim( $string )
    #
    # Where:
    #     $string is the string to trim
    #
    sub StrTrim
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

    #
    # This function determines if an error as occured
    #
    #     RLCommon::IsError( )
    #
    sub IsError
        {
        # if you use windows, FCNTL error will be ignored.
        if( !$@ || ( $^O =~ /Win32/ && $@ =~ /fcntl.*?f_getfl/ ) )
            {
            return 0;
            }

        return 1;
        }

    #
    # This function logs a line of text to the console, or where it's supposed to.
    #
    #     RLCommon::LogLine( $string )
    #
    # Where:
    #     $string is the string to log
    #
    sub LogLine
        {
        my $line    = shift;

        # If we have a logfile to write to, then don't write to the console, unless
        # we are being forced to.
        if( ( not defined( %config->{'log-file'} ) ) || defined( %config->{'force-console'} ) )
            {
            print $line;
            }

        # Write ot the logfile if we have one.
        if( defined( %config->{'log-file'} ) )
            {
            print $LogFH $line;
            }
        }

    #
    # This function returns the current log file handle if one exists, otherwise
    # stdout is returned.  This is used for IMAP debugging.
    #
    #     RLCommon::GetLogFileHandle( )
    #
    sub GetLogFileHandle
        {
        if( defined( $LogFH ) )
            {
            return $LogFH;
            }
        else
            {
            return *STDOUT;
            }
        }

    }

1;
