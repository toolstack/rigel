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
# This is the message template module for Rigel, it is
# responsible for:
#     - defining RFC822 style messages to be used for adding feeds,
#       providing help files, etc.
#

package RLTemplates;
    {
    use strict;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA=qw(Exporter);
    @EXPORT_OK=qw(AddFeed);

    sub AddFeed
        {
        my $VERSION     = shift;
        my $site_config    = shift;

        my $template_message =<<"BODY"
From: Rigel@
Subject: Template feed
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
User-Agent: Rigel version $VERSION

http://template

# See end of message for macro definitions
#
# Specify the delivery folder:
#folder = $site_config->{'folder'}
#
# Specify how to deliver every RSS feed: items/channel
#type = $site_config->{'type'}
#
# Destination mail address, the "To:" header will be set to this value
#to = $site_config->{'to'}
#
# Subject line for the messages
#subject = $site_config->{'subject'}
#
# Source mail address, the "From:" header will be set to this value
#from = $site_config->{'from'}
#
# Delivery mode for the articles: embedded, raw, text, mhtmllink, htmllink
# textlink or thtmllink
#delivery-mode = $site_config->{'delivery-mode'}
#
# Cropping of the source file: these are regular expressions that match content
# in the body of the rss item or the linked item depending on the delivery mode.
#
#crop-start = $site_config->{'crop-start'}
#crop-end = $site_config->{'crop-end'}
#
# The order articles come in from the feed: 1 = oldest to newest,
# -1 = newest to oldest
#article-order = $site_config->{'article-order'}
#
# Delete item which are "N" days old: -1 = disabled
#expire = $site_config->{'expire'}
#
# Should RIGEL expire messages that have not yet been read?: yes/no
#expire-unseen = $site_config->{'expire-unseen'}
#
# Folder to move expired mail to: undef = delete mail
#expire-folder = $site_config->{'expire-folder'}
#
# Specify if Rigel syncs mail in folder with RSS items: yes/no
#sync = $site_config->{'sync'}
#
# Use subject line based tracking: yes/no
#use-subjects = $site_config->{'use-subjects'}
#
# Define a user set time to live for a feed: -1 = disabled, 0 = ignore TTLs or
# >0 TTL in minutes
#force-ttl = $site_config->{'force-ttl'}
#
###############################################################################
#   Some of the values can use macros to substitute run time values, these
#   macros are as follows:
#
#   %{channel:dc:date}                 The channel date
#   %{channel:description}             The channel description
#   %{channel:link}                    The channel URL
#   %{channel:title}                   The channel title
#   %{dashline:channel:title}          A line of "-"'s equal to the length
#                                      of the channel title
#   %{dashline:item:title}             A line of "-"'s equal to the length
#                                      of the item title
#   %{dir:lastmod}                     The last modified folder
#   %{dir:manage}                      The management folder
#   %{dir:sep}                         The character used to seperate folder
#                                      names on the IMAP server
#   %{host}                            The IMAP server name
#   %{item:dc:creator}                 The item author
#   %{item:dc:date}                    The item date
#   %{item:dc:subject}                 The item subject
#   %{item:description}                The item description
#   %{item:link}                       The item URL
#   %{item:title}                      The item title
#   %{last-modified}                   The time the feed was last updated
#   %{newline}                         The newline character
#   %{rss-link}                        The URL of the feed
#   %{user}                            The IMAP user name
#
#   Note that not all items may be available at all times, ie. during folder
#   creation only the channel items are available as the item information has
#   not yet been proceeded.  Items not available or not recognized will be
#   replaced with blanks.
###############################################################################
BODY
;

        return $template_message;
        }
    }


1;