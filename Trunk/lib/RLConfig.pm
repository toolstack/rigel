#!/usr/bin/env perl -w

#
# Rigel - an RSS to IMAP Gateway
#
# Copyright (C) 2004 Taku Kudo <taku@chasen.org>
#               2005 Yoshinari Takaoka <mumumu@mumumu.org>
#                2008 Greg Ross <greg@darkphoton.com>
#     All rights reserved.
#     This is free software with ABSOLUTELY NO WARRANTY.
#
# You can redistribute it and/or modify it under the terms of the
# GPL2, GNU General Public License version 2.
#

#
# This is the configuration module for Rigel, it is
# responsible for:
#     - loading and parsing the configuration file
#     - Import and Export of OPML files
#     - Parsing URL lists from files and in string variables
#     - Parsing the command line options
#     - Filling in variables in to configuration items
#

package RLConfig;
    {
    use strict;
    use Encode;
    use XML::Parser;
    use XML::Parser::Expat;
    use XML::FeedPP;
    use Getopt::Long;
    use RLCommon;
    use RLUnicode;
    use RLDebug;
    use RLIMAP;
    use RLTemplates;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(LoadConfig ParseConfigString GetVersion GetGlobalConfig GetSiteConfig ApplyTemplate);

    our $VERSION = "V1.0 post release development";

    # fallback config value(real default value)
    # these values may be overridden by the config file or cmdline options.
    our $DEFAULT_GLOBAL_CONFIG =
        {
        'user'                 => $^O !~ /Win32/ ? $ENV{USER} : $ENV{USERNAME},
        'password'             => undef,
        'host'                 => 'localhost',
		'OS'				   => $^O,
        'port'                 => 143,
        'directory-separator'  => '.',
        'interval'             => 60,
        'management-folder'    => 'RSS Management',
        'last-modified-folder' => '%{dir:manage}%{dir:sep}Last Update Info',
        'prefix'               => undef,     # if you use courier, set this to "INBOX"
        'cram-md5'             => undef,
        'use-ssl'              => undef,
        'config-file'          => 'Rigel.conf',
        'VERSION'              => $VERSION,
        'debug'                => 0,
        'config-update'        => undef,
        'log-file'             => undef,
        'log-rotate'           => 'overwrite',
        'force-console'        => undef,
        };

	 if( $^O !~ /Win32/ )
		{
		if( $ENV{'HOSTNAME'} )
			{
			$DEFAULT_GLOBAL_CONFIG->{'host'} = $ENV{'HOSTNAME'};
			}
		}
	else
		{
		if( $ENV{'COMPUTERNAME'} )
			{
			$DEFAULT_GLOBAL_CONFIG->{'host'} = $ENV{'COMPUTERNAME'};
			}
		}
			
    our $DEFAULT_SITE_CONFIG =
        {
        'folder'        => 'RSS%{dir:sep}%{channel:title}',
        'type'          => 'items',
        'to'            => $DEFAULT_GLOBAL_CONFIG->{'user'},
        'subject'       => '%{item:title}',
        'from'          => $DEFAULT_GLOBAL_CONFIG->{'user'} . "@" . $DEFAULT_GLOBAL_CONFIG->{'host'},
        'delivery-mode' => 'raw',
        'expire-unseen' => 'no',
        'expire'        => -1,
        'expire-folder' => undef,
        'sync'          => 'no',
        'last-update'   => undef,
        'use-subjects'  => 'yes',
        'last-subjects' => undef,
        'force-ttl'     => -1,
        'desc'          => "",
        'crop-start'    => "",
        'crop-end'      => "",
        'article-order' => 1,
        'ignore-dates'  => 'no',
		'user-agent'    => 'Rigel/$VERSION ($^O)',
        };

    #
    # This function loads the configuration settings from the command line
    # and the config file.
    #
    #     RLConfig::LoadConfig()
    #
    sub LoadConfig
        {
        # First, parse the commnad line in case the config file location is specified
        &__ParseOptions();

        # Config value initialize.
        &__ParseConfig();

        # Now reparse the command line to override and config values set above
        &__ParseOptions();

        RLDebug::OutputDebug( 2, "Global Config Dump:", \%{$DEFAULT_GLOBAL_CONFIG} );
        RLDebug::OutputDebug( 2, "Site Config Dump:",  \%{$DEFAULT_SITE_CONFIG} );
        }

    #
    # This function updates the IMAP configuraiton messages with
    # the current template.
    #
    #     RLConfig::UpdateConfig(  $imap, \@sites)
    #
    # Where:
    #     $imap is the IMAP connection handle
    #     \@sites is an arrary reference of site config's
    #
    sub UpdateConfig
        {
        my $imap    = shift;
        my $sites   = shift;
        my ($folder) = ApplyTemplate( undef, undef, 1, "%{dir:manage}%{dir:sep}Configuration" );

        $folder = RLIMAP::GetRealFolderName( $folder, $DEFAULT_GLOBAL_CONFIG->{'directory_separator'}, $DEFAULT_GLOBAL_CONFIG->{'prefix'} );

        $imap->select( $folder );

        # First mark all the messages as deleted in the config folder.
        RLIMAP::DeleteFolderItems( $imap, $folder );

        my $sites_processed = 0;

        #Add in all of the new config messages
        for my $site_config (@{$sites})
            {
            RLCommon::LogLine( "\t$site_config->{'desc'}\r\n" );

            $imap->append_string( $folder, RLTemplates::GenerateConfig( $VERSION, $site_config ), "Seen" );

            $sites_processed++;
            }

        # Make sure all the config messages are marked as read.
        RLIMAP::MarkFolderRead( $imap, $folder );

        # Verify we now have twice as many messages in the config folder
        # as we have site configs
        if( $imap->message_count( $folder ) >= ( $sites_processed * 2 ) )
            {
            # Expunge the config folder
            $imap->expunge( $folder );
            }
        }

    #
    # This function parses a text string and extracts a URL and configuration
    # items from it.
    #
    #     RLConfig::ParseConfigString(  $feedconf, $feeddesc )
    #
    # Where:
    #     $feedconf is a feed configuration object returned by GetSiteConfig()
    #     $feeddesc is the description of the feed (usually the subject line of the configuraiton message
    #
    sub ParseConfigString
        {
        my $feedconf = shift;
        my $feeddesc = shift;

        my %config = %{$DEFAULT_SITE_CONFIG};
        my @config_list;

        $config{'desc'} = $feeddesc;

        foreach( split( "\n", $feedconf ) )
            {
            chomp;
            s/\s*$//;

            if( /^(ftp|http|https):\/\// )
                {
                $config{url} = RLCommon::StrTrim( $_ );
                }
            elsif(/^\#/ )
                {
                # It's a comment line, so don't do anything :)
                }
            elsif( /^\s*$/ )
                {
                # It's a blank link, so don't do anything :)
                }
            elsif( /^([^=]+)\s*=\s*(.*)\s*/ )
                {
                my $key   = RLCommon::StrTrim( lc( $1 ) );
                my $value = RLCommon::StrTrim( $2 );

                if( !exists $config{$key} )
                    {
                    RLCommon::LogLine( "WARNING: key value [$1] is undefined!\r\n" );
                    next;
                    }

                if ($key =~ /(expire-unseen|sync)/ && $2 =~ /^(no|0)$/i )
                    {
                    next;
                    }

                $config{$key} = RLUnicode::ToUTF8( $value );
                RLDebug::OutputDebug( 2, "config{$key} = $value\r\n" );
                }
            else
                {
                RLCommon::LogLine( "WARNING: parse error $_\r\n" );
                }
            }

        return %config;
        }

    #
    # This function sets a global configuration variable for a given setting
    #
    #     RLConfig::SetGlobalConfig(  $key, $value )
    #
    # Where:
    #     $key is the configuration variable you want to set
    #     $value is the value to set $key to
    #
    sub SetGlobalConfig
        {
        my $key      = shift;
        my $value     = shift;

        return $DEFAULT_GLOBAL_CONFIG->{$key} = $value;
        }

    #
    # This function returns the version of Rigel
    #
    #     RLConfig::GetVersion( )
    #
    sub GetVersion
        {
        return $VERSION;
        }

    #
    # This function returns the default global configuration settings
    #
    #     RLConfig::GetGlobalConfig( )
    #
    sub GetGlobalConfig
        {
        return $DEFAULT_GLOBAL_CONFIG;
        }

    #
    # This function returns the default site configuration settings
    #
    #     RLConfig::GetSiteConfig( )
    #
    sub GetSiteConfig
        {
        return $DEFAULT_SITE_CONFIG;
        }

    #
    # This function applies the Rigel configuration templates to a string
    #
    #     RLConfig::ApplyTemplate(  $rss, $item, $folder, $string)
    #
    # Where:
    #     $rss is the feed (optional)
    #     $item is the feed item (optional)
    #     $folder is a flag (t/f) (optional)
    #     $string is the string to apply the template to
    #
    sub ApplyTemplate
        {
        my $rss        = shift;
        my $item       = shift;
        my $folder_flg = shift;
        my $from       = shift;

        my %cnf;

        ($cnf{'date:sec'},$cnf{'date:min'},$cnf{'date:hour'},$cnf{'date:day'},$cnf{'date:monthnumber'},$cnf{'date:year'},$cnf{'date:weekday'},$cnf{'date:yearday'}) = localtime(time);

        $cnf{'date:dow'} = ( 'Sun', 'Mon', 'Tue', 'Wed', 'Thur', 'Fri', 'Sat' )[$cnf{'date:weekday'}];
        $cnf{'date:longdow'} = ( 'Sunday', 'Monday', 'Tueday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' )[$cnf{'date:weekday'}];
        $cnf{'date:month'} = ( "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec" )[$cnf{'date:monthnumber'}];
        $cnf{'date:longmonth'} = ( "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" )[$cnf{'date:monthnumber'}];
        $cnf{'date:year'} += 1900;
        $cnf{'date:monthnumber'} += 1;
        $cnf{'date:weekday'} += 1;
        $cnf{'date:yearday'} += 1;
        $cnf{'date:sec'} = sprintf( "%02d", $cnf{'date:sec'} );
        $cnf{'date:min'} = sprintf( "%02d", $cnf{'date:min'} );
        $cnf{'date:hour'} = sprintf( "%02d", $cnf{'date:hour'} );

        if( $rss )
            {
            $cnf{'channel:title'}       = $rss->title();
            $cnf{'channel:link'}        = $rss->link();
            $cnf{'channel:description'} = $rss->description();
            $cnf{'channel:dc:date'}     = $rss->pubDate() || "";

			$cnf{'channel:hostname'}	= $rss->link();
			$cnf{'channel:hostname'} 	=~ s/.*:\/\///;
			$cnf{'channel:hostname'} 	=~ s/\/.*$//;
			
            $cnf{'dashline:channel:title'} = "-" x length( $cnf{'channel:title'} );
            }

        if( $item )
            {
            $cnf{'item:description'}  = $item->description();
            $cnf{'item:link'}         = $item->link();
            $cnf{'item:title'}        = $item->title();
            $cnf{'item:dc:date'}      = $item->pubDate();
            $cnf{'item:dc:subject'}   = $item->category();
            $cnf{'item:dc:creator'}   = $item->author();

            $cnf{'dashline:item:title'} = "-" x length( $cnf{'item:title'} )
            }

        $cnf{host}            = $DEFAULT_GLOBAL_CONFIG->{host};
        $cnf{user}            = $DEFAULT_GLOBAL_CONFIG->{user};
		$cnf{OS}			  = $DEFAULT_GLOBAL_CONFIG->{OS};
		$cnf{version}         = $VERSION;
        $cnf{'last-modified'} = $rss->{'Rigel:last-modified'};
        $cnf{'rss-link'}      = $rss->{'Rigel:rss-link'};
        $cnf{'dir:sep'}       = $DEFAULT_GLOBAL_CONFIG->{'directory_separator'};
        $cnf{'dir:manage'}    = $DEFAULT_GLOBAL_CONFIG->{'management-folder'};
        $cnf{'dir:lastmod'}   = $DEFAULT_GLOBAL_CONFIG->{'last-modified-folder'};
        $cnf{'newline'}       = "\n";

        my @result;
        if( $from )
            {
            for my $key (keys %cnf)
                {
                if( !$cnf{$key} ) { next; }

                if( $folder_flg )
                    {
                    $cnf{$key} =~ s/\./:/g ;
                    }

                my $key2 = "%{" . $key . "}";
                $from =~ s/$key2/$cnf{$key}/eg;
                }

            $from =~ s/%{.*}//g;
            }

        return $from;
        }

    ###########################################################################
    #  Internal Functions only from here
    ###########################################################################

    #
    # This function parses the Rigel.conf file and updates the default global
    # and site configuration variables
    #
    #     __ParseConfig( )
    #
    sub __ParseConfig
        {
        my %parse_result = &__ParseConfigFile( $DEFAULT_GLOBAL_CONFIG->{'config-file'} );

        # override config value for the site definition
        while( my ($key, $value) = each %$DEFAULT_SITE_CONFIG )
            {
            if( defined( $parse_result{$key} ) )
                {
                $DEFAULT_SITE_CONFIG->{$key} = $parse_result{$key};
                }
            }

        # override config vaules for the global config
        while( my ($key, $value) = each %$DEFAULT_GLOBAL_CONFIG )
            {
            if( defined( $parse_result{$key} ) )
                {
                $DEFAULT_GLOBAL_CONFIG->{$key} = $parse_result{$key};
                }
            }
        }

    #
    # This function parses the Rigel.conf file and returns the results in a hash.
    #
    #     __ParseConfigFile( $filename )
    #
    # Where:
    #     $filename is the configuraiton file to load.
    #
    sub __ParseConfigFile
        {
        my $filename   = shift;
        my %return_hash = ();

        open( CONFFILE, $filename ) or die "$filename:Could not open configfile:$!\r\n";

        while( my $line = <CONFFILE>)
            {
            if ( $line =~ /^#/ || $line =~ /^$/ )
                {
                next;
                }

            my ($config_key, $value ) = split /=/, $line;

            $config_key = RLCommon::StrTrim( $config_key );
            $value      = RLCommon::StrTrim( $value );

            if ($value eq "undef" || $value eq "" || $value eq "no" )
                {
                $value = undef;
                }

            $return_hash{$config_key} = $value;
            }

        return %return_hash;
        }

    #
    # This function parses the command line options.
    #
    #     __ParseOptions( )
    #
    sub __ParseOptions
        {
        my @ARGV_TMP = @ARGV;

        Getopt::Long::config( 'bundling' );
        Getopt::Long::GetOptions(
                   's|host=s'                      => \$DEFAULT_GLOBAL_CONFIG->{'host'},
                   'u|user=s'                      => \$DEFAULT_GLOBAL_CONFIG->{'user'},
                   'P|port=s'                      => \$DEFAULT_GLOBAL_CONFIG->{'port'},
                   'm|last-modified-folder=s'      => \$DEFAULT_GLOBAL_CONFIG->{'last-modified-folder'},
                   'password=s'                    => \$DEFAULT_GLOBAL_CONFIG->{'password'},
                   'p|prefix=s'                    => \$DEFAULT_GLOBAL_CONFIG->{'prefix'},
                   'D|debug'                       => \$DEFAULT_GLOBAL_CONFIG->{'debug'},
                   'proxy=s'                       => \$DEFAULT_GLOBAL_CONFIG->{'proxy'},
                   'proxy-user=s'                  => \$DEFAULT_GLOBAL_CONFIG->{'proxy-user'},
                   'proxy-pass=s'                  => \$DEFAULT_GLOBAL_CONFIG->{'proxy-pass'},
                   'o|once_p'                      => \$DEFAULT_GLOBAL_CONFIG->{'once_p'},
                   'n|nodaemon'                    => \$DEFAULT_GLOBAL_CONFIG->{'nodaemon'},
                   'c|cram-md5'                    => \$DEFAULT_GLOBAL_CONFIG->{'cram-md5'},
                   'i|interval=s'                  => \$DEFAULT_GLOBAL_CONFIG->{'interval'},
                   'S|use-ssl'                     => \$DEFAULT_GLOBAL_CONFIG->{'use-ssl'},
                   'e|encrypt=s'                   => \$DEFAULT_GLOBAL_CONFIG->{'encrypt'},
                   'd|delivery-mode=s'             => \$DEFAULT_SITE_CONFIG->{'delivery-mode'},
                   'h|help'                        => \$DEFAULT_GLOBAL_CONFIG->{'help'},
                   'v|version'                     => \$DEFAULT_GLOBAL_CONFIG->{'version'},
                   'f|configfile=s'                => \$DEFAULT_GLOBAL_CONFIG->{'config-file'},
                   'R|refreshconfig'               => \$DEFAULT_GLOBAL_CONFIG->{'config-update'},
                    );

        # at this point. @ARGV reference contents is changed!.
        my @getopthold_argv = ();
        foreach my $item (@ARGV)
            {
            push @getopthold_argv, $item;
            }

        $DEFAULT_GLOBAL_CONFIG->{list} = \@getopthold_argv;

        # restore ARGV.
        @ARGV = @ARGV_TMP;
        }
    }

1;
