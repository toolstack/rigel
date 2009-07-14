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
use lib "../";

use RIGELLIB::MHTML;
use RIGELLIB::Rigel;

my $url = "http://www.askmen.com/daily/jokes/2008_aug/aug29.html";

# print out the MIME HTML output
#print RIGELLIB::MHTML->GetMHTML( $url );

# print out the HTML output
#print RIGELLIB::MHTML->GetHTML( $url );

#print out the plain text output
#print RIGELLIB::MHTML->GetTEXT( $url );

