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
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(IMAPConnect IMAPTestConnect GetLatestDate IMAPSelectFolder IMAPCreateFolder GetRealFolderName MarkFolderRead DeleteFolderItems);

    #
    # This function connects to the IMAP server and stores the connection handle
    #
    #     RLIMAP::IMAPConnect()
    #
    sub IMAPConnect
        {
        my $GLOBAL_CONFIG    = shift;
        my $ssl_sock         = undef;

        if( $GLOBAL_CONFIG->{'use-ssl'} )
            {
            eval 'use IO::Socket::SSL';

            if( RLCommon::IsError() )
                {
                RLCommon::LogLine( "ERROR: SSL cannot be used without IO::Socket::SSL installed!.\r\n" );
                RLCommon::LogLine( "       Please install it via cpan.\r\n" );

                exit();
                }

            $ssl_sock = IO::Socket::SSL->new( "$GLOBAL_CONFIG->{host}:$GLOBAL_CONFIG->{port}" )
            or die "ERROR: Could not connect to the imap server over ssl.";
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
             die "ERROR: IMAP client initialize failed. Please check your configuratino and try again.\r\n";
            }

        $GLOBAL_CONFIG->{'directory_separator'} = $imap->separator();

        # Now that we have the directory seperator, update the management
        # folder value and last modified folder value with the proper template
        # values
        $GLOBAL_CONFIG->{'management-folder'} = RLConfig::ApplyTemplate( undef, undef, 1, $GLOBAL_CONFIG->{'management-folder'} );
        $GLOBAL_CONFIG->{'last-modified-folder'} = RLConfig::ApplyTemplate( undef, undef, 1, $GLOBAL_CONFIG->{'last-modified-folder'} );

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
            RLCommon::LogLine( "ERROR: Authentication failure trying to connect to:\r\n" );
            RLCommon::LogLine( "       $GLOBAL_CONFIG->{host}:$GLOBAL_CONFIG->{port}\r\n" );

            exit();
            }

        die "ERROR: $@ $GLOBAL_CONFIG->{user}\@$GLOBAL_CONFIG->{host}\r\n" unless ($imap);

        return $imap;
        }

    #
    # This function test that the connection to the IMAP server can be made
    #
    #     RLIMAP::IMAPTestConnect()
    #
    sub IMAPTestConnect
        {
        my $imap = IMAPConnect();
        $imap->close();
        }

    #
    # This function compares IMAP message dates and returns the latest one
    #
    #     RLIMAP::GetLatestDate(  @messages, $date )
    #
    # Where:
    #     @messages is an array of message ID's to compare
    #     $date is the date to use, if omitted, the current date is used
    #
    sub GetLatestDate
        {
        my $imap    = shift;
        my $list    = shift;
        my $header  = shift || 'date';
        my $lmsg    = undef;
        my $latest  = -1;

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
    #     RLIMAP::IMAPSelectFolder(  $folder)
    #
    # Where:
    #     $folder is the folder to create/select
    #
    sub IMAPSelectFolder
        {
        my $imap    = shift;
        my $folder  = shift;

        if( ! $imap->select( $folder ) )
			{
			IMAPCreateFolder( $imap, $folder );
			$imap->select( $folder ) || RLCommon::LogLine( "@!\r\n" );
			}
        }

    #
    # This function creates an IMAP folder
    #
    #     RLIMAP::IMAPCreateFolder(  $folder)
    #
    # Where:
    #     $folder is the folder to create
    #
    sub IMAPCreateFolder
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
    #     RLIMAP::GetRealFolderName(  $folder, $dirsep)
    #
    # Where:
    #     $folder is the folder you want to get
    #     $dirsep is the directory seperator to use
    #
    sub GetRealFolderName
        {
        my $str    = shift;
        my $dirsep = shift;
        my $prefix = shift;

        if( $prefix )
            {
            $str = RLUnicode::ToUTF8( $prefix ) . $dirsep . $str;
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

        return RLUnicode::ToUTF7( $str );
        }

    #
    # This function marks all items in and IMAP folder as seen.
    #
    #     RLIMAP::MarkFolderRead( $imap, $folder )
    #
    # Where:
    #     $imap is the connection to use
    #     $folder is the folder to work on (unused)
    #
    sub MarkFolderRead
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
    #     RLIMAP::DeleteFolderItems( $imap, $folder )
    #
    # Where:
    #     $imap is the connection to use
    #     $folder is the folder to work on (unused)
    #
    sub DeleteFolderItems
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