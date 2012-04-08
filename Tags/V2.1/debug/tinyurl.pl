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
# This is a test script to make sure that the tinyurl library
# can properly shorten a link and parse it.  
#
use strict;
use warnings;
use WWW::Shorten::TinyURL;

my $long_url = "http://www.theinquirer.net/inquirer/news/2161902/cyanogenmod-announces-release-candidate?WT.rss_f=Home&WT.rss_a=Cyanogenmod+announces+7.2+release+candidate";
my $short_url = WWW::Shorten::TinyURL::makeashorterlink($long_url);

print " Long URL: " . $long_url . "\n";
print "Short URL: " . $short_url . "\n";