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
    our %config = undef;

    sub new {
        my $pkg_name = shift;
	my (%conf) = %{(shift)};

	%config = %conf;

	bless {}, $pkg_name;
    }

    sub DebugEnabled {
        return $config{'debug'};
	}

    sub OutputDebug {
	my $this = shift;
        my $string = shift;
	my $newline = shift;

	if( $newline == undef ) { $newline = 1; }

	if( $config{'debug'} ) {
	    my $parent = ( caller(1) )[3];
	    print $parent . ": " . $string;

	    if( $newline ) {
	        print "\n";
	    }
	}
    }
}

1;
