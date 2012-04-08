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
# This is a test script to make sure that the MHTML library
# can properly read a link and parse it.  If there are any issues
# receiving articles in mhtmllink, htmllink or text link mode
# simply set the URL and uncomment to code you want to run
# to test the appropriate mode.
#
use strict;
use warnings;
# Include the base RIGEL build path so we can find the RIGEL Library directory
use lib "../lib";

use RLMHTML;

my $url = "http://www.askmen.com/daily/jokes/2008_aug/aug29.html";
my $crop_start = "<div class=\"fun_stuff\">";
my $crop_end = "<div class=\"more_fun\">";

# print out the MIME HTML output
#print RLMHTML::GetMHTML( $url, $crop_start, $crop_end );

# print out the HTML output
my $output = RLMHTML::CropBody( RLMHTML::GetHTML( $url ), $crop_start, $crop_end );
print RLMHTML::MakeLinksAbsolute( $output, $url );

#print out the plain text output
#print RLMHTML::CropBody( RLMHTML::GetTEXT( $url ), $crop_start, $crop_end );

