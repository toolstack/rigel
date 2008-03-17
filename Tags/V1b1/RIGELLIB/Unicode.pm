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
# This is the unicode module for Rigel, it is
# responsible for:
#     - encoding and decoding UTF8 and UTF7 strings
#

use strict;
use Encode;
use Encode::Guess qw/euc-jp shift-jis utf8 jis/;
use Jcode;

package RIGELLIB::Unicode;
{
    sub to_utf7 {
        my $s = shift;

	# set utf8 flag
	utf8::decode ($s); 

        $s = Encode::encode ("UTF-7", $s);

        $s =~ s/\+([^\/&\-]*)\/([^\/\-&]*)\-/\+$1,$2\-/g;
        $s =~ s/&/&\-/g;
        $s =~ s/\+([^+\-]+)?\-/&$1\-/g;

	return $s;
    }


    sub to_utf8 {
        my $s       = shift;
        my $fromenc = lc(shift);

        if( $fromenc =~ /utf.*8/i ) {
            return Encode::decode("utf8", $s);
        };

        if( $fromenc ) {
            Encode::from_to($s, $fromenc,'utf8');
        }

        return Encode::decode("utf8", $s);
    }


    sub to_mime {
        my $string     = shift;
        my $fromenc    = lc(shift);

	my $return_str = undef;
        my $utf8       = undef;

        # if we can, MIME encode with UTF-8. unless we can, use iso-2022-jp.
        if( $fromenc ) {
            $utf8 = Encode::from_to( $string, $fromenc, 'utf8');

	    eval {
                $return_str = Jcode->new ( $utf8 )->MIME_Header;
            };

            if($@) {
                return Jcode->new ( $utf8 )->mime_encode;
            } else {
                return ($return_str) ? $return_str : $utf8;
            }
        } else {
            eval {
                $return_str = Jcode->new ( $string )->MIME_Header;
            };

            if($@) {
                return Encode::encode( 'MIME-Header',$string );
            } else {
                return ($return_str) ? $return_str : $string;
            }
        }
    }
}

1;
