
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
# This is a test script to make sure that the FeedPP library
# can properly read an RSS source.  It is usefull to test if
# there are any issues with the FeedPP library if you are
# not receiving articles or are getting duplicate ones.
#

use XML::FeedPP;
use HTTP::Date;

# Edit this line to ponit to the feed you want to check
my $source = 'http://thesteampunkhome.blogspot.com/feeds/posts/default';

my $feed;

# This calls the FeedPP code to retreive the Feed
eval { $feed = XML::FeedPP->new( $source ) };

# Output the Feed info
print "Title: ", $feed->title(), "\r\n";
print "Date: ", $feed->pubDate(), "\r\n";

# Output the Item info
foreach my $item ( $feed->get_item() ) {
       print "URL: ", $item->link(), "\r\n";
       print "Title: ", $item->title(), "\r\n";
       print "Date: ", $item->pubDate(), "\r\n";
       print "Category: ", $item->category(), "\r\n";
}

