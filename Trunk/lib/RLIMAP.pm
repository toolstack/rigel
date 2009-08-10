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
# This is the IMAP module for Rigel, it is
# responsible for:
#     - connecting to the IMAP server
#     - selecting and creating folders
#     - ratinalizing folder names to their IMAP namespace
#

package RLIMAP;
    {
    use strict;
    use RLCommon;
    use RLConfig;
    use RLDebug;
    use RLUnicode;
    use Mail::IMAPClient;
    use Crypt::CBC;
    use HTTP::Date;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA=qw(Exporter);
    @EXPORT_OK=qw(imap_connect imap_connect_test get_latest_date imap_select_folder imap_create_folder get_real_folder_name mark_folder_read delete_folder_items);

    #
    # This function connects to the IMAP server and stores the connection handle
    #
    #     RLIMAP::imap_connect()
    #
    sub imap_connect
        {
        my $GLOBAL_CONFIG     = shift;
        my $ssl_sock         = undef;

        if( $GLOBAL_CONFIG->{'use-ssl'} )
            {
            eval 'use IO::Socket::SSL';

            if( RLCommon::is_error() )
                {
                RLCommon::LogLine( "you specify use SSL but dont install IO::Socket::SSL.\r\n" );
                RLCommon::LogLine( "please install it via cpan.\r\n" );

                exit();
                }

            $ssl_sock = IO::Socket::SSL->new( "$GLOBAL_CONFIG->{host}:$GLOBAL_CONFIG->{port}" )
            or die "could not connect to the imap server over ssl.";
            }

        if( substr( $GLOBAL_CONFIG->{password}, 0, 16 ) == "53616c7465645f5f" )
            {
            my $cipher = Crypt::CBC->new( -key => 'rigel007', -cipher => 'DES_PP', -salt => "rigel007");

            $GLOBAL_CONFIG->{password} = $cipher->decrypt_hex( $GLOBAL_CONFIG->{password} );
            }

        my $imap = Mail::IMAPClient->new( Socket           => ( $ssl_sock ? $ssl_sock : undef ),
                                          Server           => $GLOBAL_CONFIG->{host},
                                          User             => $GLOBAL_CONFIG->{user},
                                          Port             => $GLOBAL_CONFIG->{port},
                                          Password         => $GLOBAL_CONFIG->{password},
                                          Authmechanism    => ($GLOBAL_CONFIG->{'cram-md5'} ? "CRAM-MD5" : undef),
                                          Ignoresizeerrors => 1
                                        );

        if( !$imap )
            {
             die "imap client initialize failed. maybe you dont specify proper option...\r\n";
            }

        $GLOBAL_CONFIG->{'directory_separator'} = $imap->separator();

        # Now that we have the directory seperator, update the management
        # folder value and last modified folder value with the proper template
        # values
        $GLOBAL_CONFIG->{'management-folder'} = RLConfig::apply_template( undef, undef, 1, $GLOBAL_CONFIG->{'management-folder'} );
        $GLOBAL_CONFIG->{'last-modified-folder'} = RLConfig::apply_template( undef, undef, 1, $GLOBAL_CONFIG->{'last-modified-folder'} );

        if( RLDebug::DebugEnabled( 3 ) )
            {
            $imap->Debug( 1 );
            $imap->Debug_fh( RLCommon::GetLogFileHandle() );
            }

        if( $GLOBAL_CONFIG->{'use-ssl'} )
            {
            $imap->State( 1 );  # connected
            $imap->login();     # if ssl enabled, login required because it is bypassed.
            }

        # authentication failure. sorry.
        if( !$imap->IsAuthenticated() )
            {
            RLCommon::LogLine( "Authentication failure, sorry.\r\n" );
            RLCommon::LogLine( "connected to : $GLOBAL_CONFIG->{host}:$GLOBAL_CONFIG->{port}\r\n" );

            exit();
            }

        die "$@ $GLOBAL_CONFIG->{user}\@$GLOBAL_CONFIG->{host}\r\n" unless ($imap);

        return $imap;
        }

    #
    # This function test that the connection to the IMAP server can be made
    #
    #     RLIMAP::connect_test()
    #
    sub imap_connect_test
        {
        my $imap = imap_connect();
        $imap->close();
        }

    #
    # This function compares IMAP message dates and returns the latest one
    #
    #     RLIMAP::get_latest_date(  @messages, $date )
    #
    # Where:
    #     @messages is an array of message ID's to compare
    #     $date is the date to use, if omitted, the current date is used
    #
    sub get_latest_date
        {
        my $imap    = shift;
        my $list       = shift;
        my $header     = shift || 'date';
        my $lmsg       = undef;
        my $latest     = -1;

        for my $msg (@{$list})
            {
            my $date = $imap->get_header( $msg, $header );

            if( !$date )
                {
                next;
                }

            $date = HTTP::Date::str2time( $date );
            if( $date > $latest )
                {
                $latest = $date;
                $lmsg = $msg;
                }
            }

        if( $latest == -1 )
            {
            $latest = undef;
            $lmsg = undef;
            }

        return ($latest, $lmsg);
        }

    #
    # This function selects an IMAP folder, creating it if required
    #
    #     RLIMAP::imap_select_folder(  $folder)
    #
    # Where:
    #     $folder is the folder to create/select
    #
    sub imap_select_folder
        {
        my $imap    = shift;
        my $folder  = shift;

        imap_create_folder( $imap, $folder );
        $imap->select( $folder ) || RLCommon::LogLine( "@!\r\n" );
        }

    #
    # This function creates an IMAP folder
    #
    #     RLIMAP::create_folder(  $folder)
    #
    # Where:
    #     $folder is the folder to create
    #
    sub imap_create_folder
        {
        my $imap    = shift;
        my $folder  = shift;

        if( !$imap->exists( $folder ) )
            {
            $imap->create( $folder ) || RLCommon::LogLine( "WARNING: $@\r\n" );
            }
        }

    #
    # This function returns the full IMAP path to a folder, incuding any prefix
    # and directory seperatores
    #
    #     RLIMAP::get_real_folder_name(  $folder, $dirsep)
    #
    # Where:
    #     $folder is the folder you want to get
    #     $dirsep is the directory seperator to use
    #
    sub get_real_folder_name
        {
        my $str    = shift;
        my $dirsep = shift;
        my $prefix = shift;

        if( $prefix )
            {
            $str = RLUnicode::to_utf8( $prefix ) . $dirsep . $str;
            }
        else
            {
            $str =~ s#\.#$dirsep#g;
            }

        # omit last separator.
        if( $str ne $dirsep )
            {
            $str =~ s#$dirsep$##;
            }

        return RLUnicode::to_utf7( $str );
        }

    #
    # This function marks all items in and IMAP folder as seen.
    #
    #     RLIMAP::mark_folder_read( $imap, $folder )
    #
    # Where:
    #     $imap is the connection to use
    #     $folder is the folder to work on (unused)
    #
    sub mark_folder_read
        {
        my $imap = shift;
        my $folder = shift;
        my $message;

        $imap->select( $folder );

        foreach $message ($imap->messages())
            {
            $imap->see( $message );
            }
        }

    #
    # This function marks all items in and IMAP folder as seen.
    #
    #     RLIMAP::delete_folder_items( $imap, $folder )
    #
    # Where:
    #     $imap is the connection to use
    #     $folder is the folder to work on (unused)
    #
    sub delete_folder_items
        {
        my $imap = shift;
        my $folder = shift;
        my $message;

        $imap->select( $folder );

        foreach $message ($imap->messages())
            {
            $imap->delete_message( $message );
            }
        }
    }


1;