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
    use RLConfig;

    our (@ISA, @EXPORT_OK);
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(NewFeed Help FeedSample FeedSampleList GenerateConfig);

    #
    # This function returns the template message for adding feeds
    # to Rigel
    #
    #     RLTemplates::NewFeed( $Version, $site_config )
    #
    # Where:
    #     $Version is the current version of Rigel
    #     $site_config is the configuration to use for this feed
    #
    sub NewFeed
        {
        my $VERSION        = shift;
        my $site_config = shift;

        my $template_message =<<"BODY"
From: Rigel@
Subject: $site_config->{'desc'}
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
User-Agent: Rigel $VERSION

$site_config->{'url'}

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
# Body source for the articles: feed/link/webpage
#body-source = $site_config->{'body-source'}
#
# Cropping of the body text before it is processed by any body-process 
# conversions that may occur but after it is retrieved  from the rss item or 
# website depending on the body source mode. 
#pre-crop-start = $site_config->{'pre-crop-start'}
#pre-crop-end = $site_config->{'pre-crop-end'}
#
# Convert URL's in the message body to absolute if they are relative: yes/no
#absolute-urls = $site_config->{'absolute-urls'}
#
# Process the body text to convert it to: none/text/mhtml
#body-process = $site_config->{'body-process'}
#
# Cropping of the body text after it is processed by any body-process 
# conversions. 
#post-crop-start = $site_config->{'post-crop-start'}
#post-crop-end = $site_config->{'post-crop-end'}
#
# Ignore publication dates on items, yes/no.
#ignore-dates = $site_config->{'ignore-dates'}
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
# Define a user-agent string to use
# Opera 10.01
#user-agent = Opera/9.80 (Windows NT 6.1; U; en) Presto/2.2.15 Version/10.01
# IE 8
#user-agent = Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.0)
# Firefox 3.5.5
#user-agent = Mozilla/5.0 (Windows; U; Windows NT 5.2; zh-CN; rv:1.9.1.5) Gecko/Firefox/3.5.5
#user-agent = Rigel/%{version} (%{OS})
#
###############################################################################
#   Some of the values can use macros to substitute run time values, these
#   macros are as follows:
#
#   %{channel:dc:date}                 The channel date
#   %{channel:description}             The channel description
#   %{channel:link}                    The channel URL
#   %{channel:hostname}                The hostname from the channel URL
#   %{channel:title}                   The channel title
#   %{dashline:channel:title}          A line of "-"'s equal to the length
#                                      of the channel title
#   %{dashline:item:title}             A line of "-"'s equal to the length
#                                      of the item title
#   %{dir:lastmod}                     The last modified folder
#   %{dir:manage}                      The management folder
#   %{dir:sep}                         The character used to separate folder
#                                      names on the IMAP server
#   %{host}                            The local host server name
#   %{OS}                              The local host server operating system name
#   %{version}                         The current version of Rigel
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
#   %{date:sec}                        The current seconds past the hour (0-59)
#   %{date:min}                        The current minutes past the hour (0-59)
#   %{date:hour}                       The current hour of the day (0-23)
#   %{date:day}                        The current day of the month (1-31)
#   %{date:monthnumber}                The current month's number (1-12)
#   %{date:year}                       The current year (4 digit )
#   %{date:weekday}                    The current day of the week (1=Sun, 2=Mon, etc.)
#   %{date:yearday}                    The current day of the year (1-365)
#   %{date:dow}                        The current day of the week (3 letters, first capatialized)
#   %{date:dow:lc}                     The current day of the week (3 letters, lower case)
#   %{date:dow:uc}                     The current day of the week (3 letters, upper case)
#   %{date:longdow}                    The current day of the week (long form)
#   %{date:longdow:lc}                 The current day of the week (long form, lower case)
#   %{date:longdow:uc}                 The current day of the week (long form, upper case)
#   %{date:month}                      The current month (3 letters)
#   %{date:month:lc}                   The current month (3 letters, lower case)
#   %{date:month:uc}                   The current month (3 letters, upper case)
#   %{date:longmonth}                  The current month (long form)
#   %{date:longmonth:lc}               The current month (long form, lower case)
#   %{date:longmonth:uc}               The current month (long form, upper case)
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

    #
    # This function returns the template message for help
    #
    #     RLTemplates::Help( $Version, $site_config )
    #
    # Where:
    #     $Version is the current version of Rigel
    #     $site_config is the configuration to use for this feed
    #
    sub Help
        {
        my $VERSION     = shift;
        my $site_config = shift;

        my $template_message =<<"BODY"
From: Rigel@
Subject: Help with Rigel
MIME-Version: 1.0
Content-Type: text/plain;
Content-Transfer-Encoding: 7bit
User-Agent: Rigel $VERSION

Welcome to Rigel, an RSS to IMAP gateway
----------------------------------------
        Rigel is designed to be run by a user on their own hardware and
        transfer RSS feeds to an IMAP account of the users choosing.

        Some of Rigels features include:
                * RSS 0.9, 1.0, 2.0, Atom 0.3 support.
                * text/html, text/plain mail format support.
                * You can tell Rigel to retrive the full content and add it
                  to the message instead of the content from thr RSS feed.
                * Rigel can retreive any webpage and treat it like an RSS feed.
                * You can unify unread RSS article management via IMAP. This
                  is useful in case of using multiple client.
                * IMAP over SSL support
                * Connect via proxy, proxy authentication support.
                * Generate IMAP Folder dynamically from every RSS title, and
                  so on.
                * Automatically delete expired article.
                * By executing in channel mode, it can work as simple Antenna.
                * Reduce needless traffic by using If-Modified-Since header.

        Rigel = [R]SS [I]MAP [G]ateway in p[E]r[L]

Adding Feeds
------------
        You should see a series of folders like this on your IMAP client:

                +RSS Management
                        +Add
                        +Configuration
                        +Delete
                        +Help
                        +Last Update Info

        Inside the Add folder will be a series of templates to use for adding
        new feeds to your configuration.

        To add a feed, simply edit one of these templates or create a new
        message in the Add folder.  The message should simply contain the url
        of the feed you want to add to Rigel.

        Once complete, when Rigel runs the next timet he configuration messages
        will be created in the Configuration folder and retrieve the first set
        of articles from the feeds.

        For more advanced functions, when you create the message in the Add
        folder, you can add additional items to the message body to control how
        this feed will be managed.  For example if you want this feed to be
        stored in a different folder than all your other feeds, simply add the
        following line to the message body:

                folder = Feeds%{dir:sep}Other

        The options that are available are:

                folder
                to
                subject
                from
                body-source
                pre-crop-start
                pre-crop-end
                absolute-urls
                body-process
                post-crop-start
                post-crop-end
                ignore-dates
                article-order
                expire
                expire-unseen
                expire-folder
                sync
                use-subjects
                force-ttl
                user-agent

        See the configuration file for details on these.

Macros
------
        Some of the settings in the configuration file and the feeds can use
        macros to expand information that will be available at runtime, these
        macros are as follows:

                Macro Name              Description
                %{host}                 Hostname
                %{user}                 Username
                %{rss-link}             RSS URL
                %{OS}                    OS type
                %{version}                Rigel's version
                %{dir:sep}              The IMAP server's folder separator
                %{dir:manage}           The folder that Rigel stores it's
                                        management items in
                %{dir:lastmod}          The folder that Rigel stores the RSS
                                        last modified information in
                %{last-modified}        Last-Modified header which web server
                                        returns.
                %{item:link}            Link value of every RSS item.
                %{item:title}           Title of every RSS item.
                %{item:description}     Description of every RSS item
                %{item:dc:date}         dc:date of every RSS item.(undefined
                                        in some RSS)
                %{item:dc:subject}      dc:subject of every RSS item.(undefined
                                        in some RSS)
                %{item:dc:creator}      dc:creator of every RSS item.(undefined
                                        in some RSS)
                %{channel:link}         Link of RSS channel.
                %{channel:hostname}        The hostname from the channel link.
                %{channel:title}        Title of RSS channel.
                %{channel:description}  Description of RSS channel.
                %{channel:dc:date}      dc:date of RSS channel. (undefined in
                                        some RSS)
                %{date:sec}             The current seconds past the hour (0-59)
                %{date:min}             The current minutes past the hour (0-59)
                %{date:hour}            The current hour of the day (0-23)
                %{date:day}             The current day of the month (1-31)
                %{date:monthnumber}     The current month's number (1-12)
                %{date:year}            The current year (4 digit )
                %{date:weekday}         The current day of the week (1=Sun, 2=Mon, etc.)
                %{date:yearday}         The current day of the year (1-365)
                %{date:dow}             The current day of the week (3 letters, first capatialized)
                %{date:dow:lc}          The current day of the week (3 letters, lower case)
                %{date:dow:uc}          The current day of the week (3 letters, upper case)
                %{date:longdow}         The current day of the week (long form)
                %{date:longdow:lc}      The current day of the week (long form, lower case)
                %{date:longdow:uc}      The current day of the week (long form, upper case)
                %{date:month}           The current month (3 letters)
                %{date:month:lc}        The current month (3 letters, lower case)
                %{date:month:uc}        The current month (3 letters, upper case)
                %{date:longmonth}       The current month (long form)
                %{date:longmonth:lc}    The current month (long form, lower case)
                %{date:longmonth:uc}    The current month (long form, upper case)

Body Source
-----------
        Rigel can retreive the body of an article from three different sources:

                - feed
                        Uses whatever the feed provides in the article description
                - link
                        Rigel will act like a web browser and connect to the link
                        provided in the feed and retreive the entire webpage.
                - webpage
                        Rigel will assume that this is not really an RSS feed at all
                        and instead is just a standalone website.  Rigel will connect
                        to it as a browser and retrieve the entire webpage.

        By default, Rigel will connect using a user agent string in the following 
        format:
        
                Rigel/%{version} (%{OS})
                
        However, some websites may require a more conventional user agent string and
        so this can be configured on a per feed basis.
        
Body Process
------------
        Once Rigel has the artcile body it can process it in several ways:

                - Raw Feed (none)
                        Uses whatever the feed provides (usually a mix of
                        text with some HTML markup)
                - Text (text)
                        All items are converted to plain text (7-bit ASCII)
                - MHTML (mhtml)
                        Retrieve the webpage in the rss link and convert it
                        to a mime HTML mail message with all css and images
                        embedded in the message.  This allows for offline
                        reading, but can generate very large messages.

        You can configure delivery mode by setting "delivery-mode" value in
        Rigel.conf, and can override its value with command line option "-d".

BODY
;

        return $template_message;
        }

    #
    # This function returns an array of all the sample feed configuration
    # names to add to the Help folder
    #
    #     RLTemplates::FeedSampleList()
    #
    sub FeedSampleList
        {
        return ( "register.co.uk",
                 "theinquirer.net",
                 "aintitcool.com",
                 "penny-arcade.com",
                 "wired.com",
                 "slashdot.org"
                 );
        }

    #
    # This function returns the template message a sample feed
    # to Rigel
    #
    #     RLTemplates::FeedSample( $Version, $site_config, $name )
    #
    # Where:
    #     $Version is the current version of Rigel
    #     $site_config is the configuration to use for this feed
    #     $name is the name of the sample to return
    #
    sub FeedSample
        {
        my $VERSION     = shift;
        my $temp_site   = shift;
        my $samplename  = lc( shift );

        # Perl passes all parameters in to functions by reference, therefore
        # if we change a value here it will change the value from the calling
        # location as well.  We don't want that, so first dereference the hash
        # so that we make a copy of the hash instead of the hash reference.  
        # Then make a copy to a new hash.
        my %temp = %$temp_site;
        # Now create a reference to the new hash so we can work with it more 
        # easily.  We will now have a reference to a copy of the passed hash.
        my $site_config = \%temp;
        
        if( $samplename eq "register.co.uk" )
            {
            $site_config->{'desc'} = "The Register";
            $site_config->{'url'} = "http://www.theregister.co.uk/headlines.rss";
            $site_config->{'subject'} = "%{item:title} [%{item:link}]";
            $site_config->{'body-source'} = "link";
            $site_config->{'pre-crop-start'} = "<div id=\"article\">";
            $site_config->{'pre-crop-end'} = "<p class=\"wptl btm\">";
            $site_config->{'body-process'} = "text";
            $site_config->{'order'} = "-1";
            }
        elsif( $samplename eq "theinquirer.net" )
            {
            $site_config->{'desc'} = "The Inquirer";
            $site_config->{'url'} = "http://feeds.theinquirer.net/feed/vnunet/the_INQUIRER";
            $site_config->{'subject'} = "%{item:title} [%{item:link}]";
            $site_config->{'body-source'} = "link";
            $site_config->{'pre-crop-start'} = "<div class=\"contentparent\">";
            $site_config->{'pre-crop-end'} = "<div class=\"article_page_ads_bottom\">";
            }
        elsif( $samplename eq "aintitcool.com" )
            {
            $site_config->{'desc'} = "Ain't it Cool News";
            $site_config->{'url'} = "http://www.aintitcool.com/node/feed";
            $site_config->{'subject'} = "%{item:title} [%{item:link}]";
            $site_config->{'delivery-mode'} = "link";
            $site_config->{'pre-crop-start'} = "<tr valign=\"top\" class=\"articlenews\">";
            $site_config->{'pre-crop-end'} = "</base>";
            }
        elsif( $samplename eq "penny-arcade.com" )
            {
            $site_config->{'desc'} = "Penny Arcade";
            $site_config->{'url'} = "http://www.penny-arcade.com/rss.xml";
            }
        elsif( $samplename eq "wired.com" )
            {
            $site_config->{'desc'} = "Wired News";
            $site_config->{'url'} = "http://feeds.wired.com/wired/index";
            }
        else
            {
            $site_config->{'desc'} = "Slashdot News";
            $site_config->{'url'} = "http://rss.slashdot.org/Slashdot/slashdot";
            }

        return GenerateConfig( $VERSION, $site_config );
        }

    #
    # This function returns the config message that would generate
    # the $site_config array
    #
    #     RLTemplates::GenerateConfig( $Version, $site_config )
    #
    # Where:
    #     $Version is the current version of Rigel
    #     $site_config is the configuration to use for this feed
    #
    sub GenerateConfig
        {
        my $VERSION     = shift;
        my $site_config = shift;
        my $item        = "";
        my $default_site = RLConfig::GetSiteConfig();

        # Retreive the standard Add Feed template.
        my $template_message = NewFeed( $VERSION, $site_config );

        # Retreive the template items that can change.
        my $template_items = __TemplateItems( $site_config );

        # Loop through each possible item in the site config.
        while ( ($item) = each( %{$site_config} ) )
            {
            # If the item value is not the default from the config file, uncomment
            # it in the message body.
            if( $site_config->{$item} ne $default_site->{$item} )
                {
                my $replace = $template_items->{$item};
                my $with = $replace;
                $with =~ s/^#//;

                $template_message =~ s/\Q$replace\E/$with/;
                }
            }

        return $template_message;
        }

    ###########################################################################
    #  Internal Functions only from here
    ###########################################################################

    #
    # This function returns all the possible settings in the template
    # message that can be changed as an array.
    #
    #     __TemplateItems( $site_config )
    #
    # Where:
    #     $site_config is the configuration to use for this feed
    #
    sub __TemplateItems
        {
        my $site_config = shift;
        my $item        = ();

        # These are the configuriaton items that appear in the standard add feed template
        # each one can be replaced with something specific to the feed, you must replace
        # $name and $url.
        $item->{'desc'}            = "Subject: $site_config->{'desc'}";
        $item->{'url'}             = $site_config->{'url'};
        $item->{'folder'}          = "#folder = $site_config->{'folder'}";
        $item->{'subject'}         = "#subject = $site_config->{'subject'}";
        $item->{'body-source'}     = "#body-source = $site_config->{'body-source'}";
        $item->{'pre-crop-start'}  = "#pre-crop-start = $site_config->{'pre-crop-start'}";
        $item->{'pre-crop-end'}    = "#pre-crop-end = $site_config->{'pre-crop-end'}";
        $item->{'body-process'}    = "#body-process = $site_config->{'body-process'}";
        $item->{'absolute-urls'}   = "#absolute-urls = $site_config->{'absolute-urls'}";
        $item->{'post-crop-start'} = "#post-crop-start = $site_config->{'post-crop-start'}";
        $item->{'post-crop-end'}   = "#post-crop-end = $site_config->{'post-crop-end'}";
        $item->{'article-order'}   = "#article-order = $site_config->{'article-order'}";
        $item->{'to'}              = "#to = $site_config->{'to'}";
        $item->{'from'}            = "#from = $site_config->{'from'}";
        $item->{'expire'}          = "#expire = $site_config->{'expire'}";
        $item->{'expire-unseen'}   = "#expire-unseen = $site_config->{'expire-unseen'}";
        $item->{'expire-folder'}   = "#expire-folder = $site_config->{'expire-folder'}";
        $item->{'sync'}            = "#sync = $site_config->{'sync'}";
        $item->{'use-subjects'}    = "#use-subjects = $site_config->{'use-subjects'}";
        $item->{'force-ttl'}       = "#force-ttl = $site_config->{'force-ttl'}";
        $item->{'ignore-dates'}    = "#ignore-dates = $site_config->{'ignore-dates'}";
        $item->{'user-agent'}      = "#user-agent = Rigel/%{version} (%{OS})";

        return $item;
        }
    }


1;