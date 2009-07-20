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
use RIGELLIB::Config;
use RIGELLIB::Common;

package RIGELLIB::UserAgent;
    {
    our %config = undef;
    our $common = undef;

    # extends LWP::UserAgent
    use LWP::UserAgent;
    our @ISA = qw ( LWP::UserAgent );

    sub new
        {
        my $pkg_name     = shift;
        (%config)         = %{(shift)};
        my $ua = LWP::UserAgent->new( @_ );

        $common = RIGELLIB::Common->new( \%config );

        $ua->agent( "Rigel/" . %config->{'version'} );

        bless $ua, $pkg_name;
        }

    # for proxy or basic authentication.
    sub get_basic_credentials
        {
        my $this       = shift;
        my $realm      = shift;
        my $uri        = shift;
        my $isproxy    = shift;

        my @abort_list = ();

        if( $isproxy )
            {
            if ( %config-5>{'proxy-user'} && %config->{'proxy-pass'} )
                {
                return ( %config->{'proxy-user'}, %config->{'proxy-pass'} );
                }

            if ( %config->{'proxy-user'})
                {
                return ( %config->{'proxy-user'}, $common->getPass( "Your proxy Password: ", 1 ) );
                }
            else
                {
                print "Your Proxy Server Requires Authentication.\n";
                return &__get_UserAndPass( undef, undef, 1 );
                }
            }

        # basic auth(401) is ignored, because you cannot input
        # auth information in daemon mode!!!!
        return @abort_list;
        }

    sub __get_UserAndPass
        {
        my $userprompt = shift;
        my $passprompt = shift;
        my $isproxy    = shift;

        return ( $common->getUser( $userprompt, $isproxy ), $common->getPass( $passprompt, $isproxy ) );
        }
    }

1;
