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
# This is the user agent module for Rigel, it is
# responsible for:
#     - Handling proxy authentication
#

use strict;
use Common;

package RIGELLIB::UserAgent;
    {
    our %config = undef;

    # extends LWP::UserAgent
    use LWP::UserAgent;
    our @ISA = qw ( LWP::UserAgent );

    sub new
        {
        my $pkg_name     = shift;
        (%config)        = %{(shift)};
        my $ua = LWP::UserAgent->new( @_ );

        $ua->agent( "Rigel/" . %config->{'version'} );

        bless $ua, $pkg_name;
        }

    #
    # This function retrives a set of basic credientals for a proxy server
    # either from the config file or interactivly.
    #
    #     RIGELLIB::UserAgent->get_basic_credentials(  $realm, $uri, $isproxy )
    #
    # Where:
    #     $realm is HTTP realm setting (unused at this time)
    #     $uri is the url this is for (unused at this time)
    #     $isproxy is wether this is for a proxy server or not (t/f)
    #
    sub get_basic_credentials
        {
        my $this       = shift;
        my $realm      = shift;
        my $uri        = shift;
        my $isproxy    = shift;

        my @abort_list = ();

        if( $isproxy )
            {
            if ( %config->{'proxy-user'} && %config->{'proxy-pass'} )
                {
                return ( %config->{'proxy-user'}, %config->{'proxy-pass'} );
                }

            if ( %config->{'proxy-user'})
                {
                return ( %config->{'proxy-user'}, Common::getPass( "Your Proxy Password: ", 1 ) );
                }
            else
                {
                print "Your Proxy Server Requires Authentication.\n";
                return ( Common::getUser( undef, $isproxy ), Common::getPass( undef, $isproxy ) );
                }
            }

        # basic auth(401) is ignored, because you cannot input
        # auth information in daemon mode!!!!
        return @abort_list;
        }
    }

1;