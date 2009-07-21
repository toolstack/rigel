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
# This is the debug module for Rigel, it is
# responsible for:
#     - outputing debug information
#

use strict;

package RIGELLIB::Debug;
    {
    use Data::Dumper;

    our %config = undef;

    sub new
        {
        my $pkg_name = shift;
        my (%conf) = %{(shift)};

        %config = %conf;

        bless {}, $pkg_name;
        }

    #
    # This function returns true/false depending upon if debugging is enabled
    # at a given level.  Usage should be:
    #
    #     RIGELLIB::Debug->DebugEnabled( $level )
    #
    # Where:
    #     $level is a value between 0 and 3.
    #
    sub DebugEnabled
        {
        my $this = shift;
        my $level = shift;

        if( $config{'debug'} >= $level )
            {
            return 1;
            }
        else
            {
            return 0;
            }
        }

    #
    # This function outputs debug information if debugging is enabled
    # at a given level.  Usage should be:
    #
    #     RIGELLIB::Debug->OutputDebug( $level, $string, $variable )
    #
    # Where:
    #     $level is the desired output level to execute at
    #     $string is the string to output (do not line terminate, it
    #          will be added automatically)
    #     $variable is a variable to pass to Data::Dumper
    #
    # The line output format will be:
    #
    #     [Date/Time][Calling function] [$string]
    #     [$var dump if exists]
    #
    sub OutputDebug
        {
        my $this = shift;
        my $level = shift;
        my $string = shift;
        my $var = shift;

        if( $config{'debug'} >= $level )
            {
            my $parent = ( caller(1) )[3];
            print "[" . localtime() . "] " . $parent . ": " . $string . "\n";

            if( defined( $var ) )
                {
                print Data::Dumper::Dumper( $var ) . "\n";
                }
            }
        }
    }

1;
