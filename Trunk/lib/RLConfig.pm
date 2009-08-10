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
    @ISA=qw(Exporter);
    @EXPORT_OK=qw(LoadConfig import_file parse_url_list parse_url_list_from_string export_file get_global_conf get_site_conf get_version get_global_configall get_site_configall apply_template);

    our $VERSION = "V1 post-b5 development";

    # fallback config value(real default value)
    # this value may be overridden by config file and cmdline option.
    our $DEFAULT_GLOBAL_CONFIG =
        {
        'user'                 => $ENV{USER},
        'password'             => undef,
        'host'                 => 'localhost',
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

    our $DEFAULT_SITE_CONFIG =
        {
        'folder'        => 'RSS%{dir:sep}%{channel:title}',
        'type'          => 'items',
        'to'            => $DEFAULT_GLOBAL_CONFIG->{'user'},
        'subject'       => '%{item:title}',
        'from'          => $ENV{'USER'} . '@' . ($ENV{'HOSTNAME'} ? $ENV{'HOSTNAME'} : "localhost"),
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
        };

    # opml parse result.
    our $opml_parse = undef;
    our @folder_array = ();
    our $outline_empty = 0;

    sub LoadConfig
        {
        # First, parse the commnad line in case the config file location is specified
        &__parse_options();

        # Config value initialize.
        &__parse_conf();

        # Now reparse the command line to override and config values set above
        &__parse_options();

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
        my ($folder) = RLConfig::apply_template( undef, undef, 1, "%{dir:manage}%{dir:sep}Configuration" );

        $folder = RLIMAP::get_real_folder_name( $folder, $DEFAULT_GLOBAL_CONFIG->{'directory_separator'}, $DEFAULT_GLOBAL_CONFIG->{'prefix'} );

        $imap->select( $folder );

        # First mark all the messages as deleted in the config folder.
        RLIMAP::delete_folder_items( $imap, $folder );

        my $sites_processed = 0;

        #Add in all of the new config messages
        for my $site_config (@{$sites})
            {
            RLCommon::LogLine( "\t$site_config->{'desc'}\r\n" );

            $imap->append_string( $folder, RLTemplates::GenerateConfig( $VERSION, $site_config ), "Seen" );

            $sites_processed++;
            }

        # Make sure all the config messages are marked as read.
        RLIMAP::mark_folder_read( $imap, $folder );

        # Verify we now have twice as many messages in the config folder
        # as we have site configs
        if( $imap->message_count( $folder ) >= ( $sites_processed * 2 ) )
            {
            # Expunge the config folder
            $imap->expunge( $folder );
            }
        }

    #
    # This function imports an OPML file
    #
    #     RLConfig::import_file(  $filename )
    #
    # Where:
    #     $filename is the fully qulified file name to import
    #
    sub import_file
        {
        my $filename = shift;

        my $output_file = get_global_conf( 'outfile' );

        # parameter check.
        if( !defined $filename )
            {
            RLCommon::LogLine( "import : you should spefify opml filename after [-I|--import] option.\r\n" );
            }

        if( !defined $output_file )
            {
            RLCommon::LogLine( "import : you should spefify output filename after [-O] option.\r\n" );
            }

        if( !defined $filename || !defined $output_file )
            {
            RLCommon::LogLine( "Usage: ./Rigel [-I|--import] [opml filename] -O [site filename].\r\n" );
            exit();
            }

        if( !$filename || !(-e $filename) )
            {
            RLCommon::LogLine( "import: File does not exist : $filename\r\n" );
            exit();
            }

        my $parser = new XML::Parser(
                            Handlers => {
                                Start => \&__start_tag_handler,
                                End   => \&__end_tag_handler,
                            }
                     );

        $opml_parse = {};

        RLCommon::LogLine( "parsing opml file...: $filename\r\n" );

        # parse opml file.
        eval{ $parser->parsefile( $filename ); };

        if ($@ )
            {
            RLCommon::LogLine( "import process failed : $@" );
            exit();
            }

        # output result here.
        __print_config_file( $output_file );

        RLCommon::LogLine( "finished generating site file successfully -> $output_file\r\n" );
        exit();
        }

    #
    # This function parses a URL list from the old rss2imap utlity, it should
    # be depricated at this point.
    #
    #     RLConfig::parse_url_list(  @filename )
    #
    # Where:
    #     @filename is the fully qulified file name array to parse
    #
    sub parse_url_list
        {
        my @filenames =  shift;

        my %config = %{$DEFAULT_SITE_CONFIG};
        my @config_list;

        for my $filename (@filenames)
            {
            open( F, $filename ) || die "$! : $filename\r\n";

            while( <F> )
                {
                chomp;
                s/\s*$//;
                if( /^(ftp|http|https):\/\// )
                    {
                    $config{url}  = RLCommon::str_trim( $_ );
                    }
                elsif( /^\#/ )
                    {
                    }
                elsif( /^([^:]+)\s*:\s*(.*)\s*/ )
                    {
                    my $key   = RLCommon::str_trim( lc( $1 ) );
                    my $value = RLCommon::str_trim( $2 );

                    if( !exists $config{$key} )
                        {
                        RLCommon::LogLine( "WARNING: key value [$1] is undefined!\r\n" );
                        next;
                        }

                    if( $key =~ /(expire-unseen|sync)/ && $2 =~ /^(no|0)$/i )
                        {
                        next;
                        }

                    $config{$key} = RLUnicode::to_utf8( $value );
                    }
                elsif( /^\s*$/ )
                    {
                    if (keys %config) { push @config_list, { %config }; }
                    %config = %{$DEFAULT_SITE_CONFIG};
                    }
                else
                    {
                    RLCommon::LogLine( "WARNING: parse error $_\r\n" );
                    }
                }

            close( F );
            if (keys %config) { push @config_list, { %config }; }
            }

        return \@config_list;
        }

    #
    # This function parses a URL list from a string, it is the new code used
    # to replace parse_url_list in Rigel.
    #
    #     RLConfig::parse_url_list_from_string(  $feedconf, $feeddesc )
    #
    # Where:
    #     $feedconf is a feed configuration object returned by get_site_conf()
    #     $feeddesc is the description of the feed (usually the subject line of the configuraiton message
    #
    sub parse_url_list_from_string
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
                $config{url} = RLCommon::str_trim( $_ );
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
                my $key   = RLCommon::str_trim( lc( $1 ) );
                my $value = RLCommon::str_trim( $2 );

                if( !exists $config{$key} )
                    {
                    RLCommon::LogLine( "WARNING: key value [$1] is undefined!\r\n" );
                    next;
                    }

                if ($key =~ /(expire-unseen|sync)/ && $2 =~ /^(no|0)$/i )
                    {
                    next;
                    }

                $config{$key} = RLUnicode::to_utf8( $value );
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
    # This function exports an OPML file from the Rigel configuration.
    #
    #     RLConfig::export_file(  @filename )
    #
    # Where:
    #     @filename is an array of file names to export, only one should be passed
    #
    sub export_file
        {
        my @filenames   = shift;

        my $output_file = get_global_conf( 'outfile' );

        # parameter check.
        if( !@filenames || !defined $filenames[0] )
            {
            RLCommon::LogLine( "export : you should spefify site filename after [-E|--export] option.\r\n" );
            }

        if( !defined $output_file )
            {
            RLCommon::LogLine( "export : you should spefify output file with [-O] option.\r\n" );
            }

        if( !defined $filenames[0] || !defined $output_file )
            {
            RLCommon::LogLine( "Usage: ./Rigel [-E|--export] [site filename] -O [opml filename].\r\n" );
            exit();
            }

        # get proxy pass if enabled
        RLCommon::getProxyPass_ifEnabled();

        # open output file. if output file exists, ask if overwrite it.
        my ($out_fh) = &__find_and_ask( 'export', $output_file, 0 );

        # get config list.
        # this array is composed of ${DEFAULT_SITE_CONFIG}
        # which value is overridden by url list.
        RLCommon::LogLine( "export: parsing site file...\r\n" );
        my @config_list = @{parse_url_list( @filenames )};

        # sort array by 'folder' key.
        @config_list = &__sort_array_byfolder( @config_list );
        if( scalar(@config_list) == 0 )
            {
            RLCommon::LogLine( "No configuration found from your site file.\r\n" );
            exit();
            }

        my $opml_header = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                        . "<opml version=\"1.0\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\""
                        . " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n"
                        . "<head>Generated by Rigel $VERSION</head>\n<body>\n";
        my $opml_footer = "</body>\n</opml>";

        # print result to file...start.
        print $out_fh $opml_header;

        my @added_list = ();      # processed folder list.
        my $isfirst = 1;          # is first loop?
        my $indent_num = 0;       # indent level
        my $indent_str = " " x 4; # indent string is space x 4

        foreach my $config (@config_list)
            {
            # remove %{.*} macro from foldername
            $config->{'folder'} =~ s/\.%\{.*\}//g;

            my @folder_list = split /\./,$config->{'folder'};

            # adjust outline tag.
            foreach my $folder_name (@folder_list)
                {
                # from second processing, adjust opml end tag.
                if( $isfirst == 0 )
                    {
                    foreach my $added_name (@added_list)
                        {
                        if( scalar( grep /$added_name/, @folder_list ) == 0 )
                            {
                            pop @added_list;
                            $indent_num--;
                            print $out_fh $indent_str x $indent_num;
                            print $out_fh "</outline>\n";
                            }
                        }
                    }

                # print outline for folder name
                if( scalar( grep /$folder_name/, @added_list) == 0 )
                    {
                    push @added_list, $folder_name;
                    print $out_fh $indent_str x $indent_num;
                    print $out_fh "<outline title=\"$folder_name\">\n";
                    $indent_num++;
                    }
                }

            # print uris.
            foreach my $link (@{$config->{'url'}})
                {
                RLCommon::LogLine( "processing $link ....\r\n" );
                my @rss_and_response = RLCommon::getrss_and_response( $link, {} );

                if ( scalar(@rss_and_response) == 0 )
                    {
                    next;
                    }

                my $content = $rss_and_response[0];
                my $rss = undef;

                eval { $rss = XML::FeedPP->new( $content ); };

                if( $@ )
                    {
                    RLCommon::LogLine( "WARNING: feed error, skip this url...\r\n" );
                    next;
                    }

                my $title       = &__xmlval_convert( $rss->title() );
                my $description = &__xmlval_convert( $rss->description() );
                my $xml_link    = &__xmlval_convert( $link );
                my $htmlurl     = &__xmlval_convert( $rss->link() );

                print $out_fh $indent_str x $indent_num;
                print $out_fh "<outline type='rss' ";
                print $out_fh "title='" . $title . "' ";
                print $out_fh "description='" . $description . "' ";
                print $out_fh "xmlUrl='" . $xml_link . "' ";
                print $out_fh "htmlUrl='" . $htmlurl . "' />\n";
                }

            $isfirst = 0;  # not first processing any more.
            }

        # last outline close tag and opml footer.
        foreach my $added_name (@added_list)
            {
            $indent_num--;
            print $out_fh $indent_str x $indent_num;
            print $out_fh "</outline>\n";
            }

        print $out_fh $opml_footer;

        RLCommon::LogLine( "finished generating opml file successfully -> $output_file\r\n" );
        exit();
        }

    #
    # This function returns a global configuration variable for a given setting
    #
    #     RLConfig::get_global_conf(  $key )
    #
    # Where:
    #     $key is the configuration variable you want the setting for
    #
    sub get_global_conf
        {
        my $key  = shift;

        return $DEFAULT_GLOBAL_CONFIG->{$key};
        }

    #
    # This function returns a global configuration variable for a given setting
    #
    #     RLConfig::set_global_conf(  $key, $value )
    #
    # Where:
    #     $key is the configuration variable you want to set
    #     $value is the value to set $key to
    #
    sub set_global_conf
        {
        my $key      = shift;
        my $value     = shift;

        return $DEFAULT_GLOBAL_CONFIG->{$key} = $value;
        }

    #
    # This function returns a site configuration variable for a given setting
    #
    #     RLConfig::get_site_conf(  $key )
    #
    # Where:
    #     $key is the configuration variable you want the setting for
    #
    sub get_site_conf
        {
        my $key  = shift;

        return $DEFAULT_SITE_CONFIG->{$key};
        }

    #
    # This function returns the version of Rigel
    #
    #     RLConfig::get_version( )
    #
    sub get_version
        {
        return $VERSION;
        }

    #
    # This function returns the default global configuration settings
    #
    #     RLConfig::get_global_conf( )
    #
    sub get_global_configall
        {
        return $DEFAULT_GLOBAL_CONFIG;
        }

    #
    # This function returns the default site configuration settings
    #
    #     RLConfig::get_global_conf( )
    #
    sub get_site_configall
        {
        return $DEFAULT_SITE_CONFIG;
        }

    #
    # This function applies the Rigel configuration templates to a string
    #
    #     RLConfig::apply_template(  $rss, $item, $folder, $string)
    #
    # Where:
    #     $rss is the feed (optional)
    #     $item is the feed item (optional)
    #     $folder is a flag (t/f) (optional)
    #     $string is the string to apply the template to
    #
    sub apply_template
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
        
        if( $rss )
            {
            $cnf{'channel:title'}       = $rss->title();
            $cnf{'channel:link'}        = $rss->link();
            $cnf{'channel:description'} = $rss->description();
            $cnf{'channel:dc:date'}     = $rss->pubDate() || "";

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
    # This function converts an array to a hash
    #
    #     __array_to_hash(  @array )
    #
    # Where:
    #     @array is the array to convert
    #
    sub __array_to_hash
        {
        my $hash_ref = {};

        for( ; @_ ; )
            {
            my $key = shift;
            my $value = shift;

            $hash_ref->{$key} = $value;
            }

        return $hash_ref;
        }

    #
    # This function parses the Rigel.conf file and updates the default global
    # and site configuration variables
    #
    #     __parse_conf( )
    #
    sub __parse_conf
        {
        my %parse_result = &__parse_conffile( $DEFAULT_GLOBAL_CONFIG->{'config-file'} );

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
    #     __parse_conffile( $filename )
    #
    # Where:
    #     $filename is the configuraiton file to load.
    #
    sub __parse_conffile
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

            $config_key = RLCommon::str_trim( $config_key );
            $value      = RLCommon::str_trim( $value );

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
    #     __parse_options( )
    #
    sub __parse_options
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

    #
    # This function converts ascii characters to HTML/XML entities versions.
    # Only used in the export function.
    #
    #     __xmlval_convert( $string )
    #
    # Where:
    #     $string is the string to convert
    #
    sub __xmlval_convert()
        {
        my $str = shift;

        if( !defined $str )
            {
            return "";
            }

        chomp $str;
        $str =~ s/</&lt;/g;
        $str =~ s/>/&gt;/g;
        $str =~ s/&/&amp;/g;
        $str =~ s/"/&quot;/g;
        $str =~ s/'/&apos;/g;

        return Encode::encode( "utf8", $str );
        }

    #
    # This function converts ascii characters to HTML/XML entities versions.
    # Only used in the import function.
    #
    #     __print_config_file( $filename )
    #
    # Where:
    #     $filename is the full path to the filename to output
    #
    sub __print_config_file()
        {
        my $output_file = shift;

        my %parse_result = %{$opml_parse};

        # open output file. if output file exists, ask what to do.
        my ($out_fh,$can_append) = &__find_and_ask( 'import', $output_file, 1 );

        # print header
        if( $can_append )
            {
            print $out_fh "\n";
            }
        else
            {
            print $out_fh "#\n";
            print $out_fh "#    Generated by Rigel $VERSION import script\n";
            print $out_fh "#    Note: Config value is used one in the config file.\n";
            print $out_fh "#          if you want to change, edit Rigel.conf\n";
            print $out_fh "#\n\n";
            }

        foreach my $key (sort keys %parse_result )
            {
            my $value = $parse_result{$key};

            if ( scalar(@{$value}) == 0 )
                {
                next;
                }

            print $out_fh Encode::encode( "utf8", "folder: RSS.$key.%{channel:title}\n" );
            print $out_fh Encode::encode( "utf8", "type: $DEFAULT_SITE_CONFIG->{'type'}\n" );
            print $out_fh Encode::encode( "utf8", "subject: $DEFAULT_SITE_CONFIG->{'subject'}\n" );
            print $out_fh Encode::encode( "utf8", "from: $DEFAULT_SITE_CONFIG->{'from'}\n" );
            print $out_fh Encode::encode( "utf8", "expire-unseen: $DEFAULT_SITE_CONFIG->{'expire-unseen'}\n" );
            print $out_fh Encode::encode( "utf8", "expire: $DEFAULT_SITE_CONFIG->{'expire'}\n" );
            print $out_fh Encode::encode( "utf8", "expire-folder: $DEFAULT_SITE_CONFIG->{'expire-folder'}\n" );
            print $out_fh Encode::encode( "utf8", "sync: $DEFAULT_SITE_CONFIG->{'sync'}\n" );

            foreach my $xml_uri (@{$value})
                {
                print $out_fh RLUnicode::to_utf8( "$xml_uri\n" );
                }

            print $out_fh "\n";
            }
        }

    #
    # This function sorts an array by the 'folder' key value.
    #
    #     __sort_array_byfolder( @array )
    #
    # Where:
    #     @array is the array to sort
    #
    sub __sort_array_byfolder
        {
        my @array = @_;
        my @key_array = ();
        my @return_array = ();

        foreach my $item (@array)
            {
            push @key_array, $item->{'folder'};
            }

        @key_array = sort @key_array;

        RLDebug::OutputDebug( 2, "Array Dump:", \@key_array );

        foreach my $key_item (@key_array)
            {
            foreach my $param_item (@array)
                {
                if( !exists $param_item->{'url'} )
                    {
                    next;
                    }

                push @return_array, $param_item if( $key_item eq $param_item->{'folder'} );
                }
            }

        return @return_array;
        }

    #
    # This function asks a user what to do in case an export file already exists
    #
    #     __find_and_ask(  $cmd, $filename, $append)
    #
    # Where:
    #     $cmd is the command time being executed (import/export)
    #     $filename is the full path and filename to check
    #     $append is wether the append option is avaliable in this case (t/f)
    #
    sub __find_and_ask()
        {
        my $cmdname     = shift;
        my $output_file = shift;
        my $can_append  = shift;

        # ask if overwrite, append, or abort.
        if( -e $output_file && $can_append )
            {
            RLCommon::LogLine( "\r\n$output_file already exists! overwrite?[O], append?[A], or exit?[E] (O/A/E):" );
            my $answer = <STDIN>;
            chomp $answer;

            if( $answer =~ /O/i )
                {
                open OUTFILE, ">$output_file" or die "could not open output file:$!";
                return( *OUTFILE{IO}, 0 );
                }
            elsif( $answer =~ /A/i )
                {
                open OUTFILE, ">>$output_file" or die "could not open output file:$!";
                return( *OUTFILE{IO}, 1 );
                }
            else
                {
                RLCommon::LogLine( "$cmdname aborted by user.\r\n" );
                exit();
                }
            }

        if( -e $output_file && !$can_append )
            {
            RLCommon::LogLine( "\r\n$output_file already exists! overwrite? (y/N):" );
            my $answer = <STDIN>;
            chomp $answer;

            if( $answer =~ /Y/i )
                {
                open OUTFILE, ">$output_file" or die "could not open output file:$!";
                return( *OUTFILE{IO} );
                }
            else
                {
                RLCommon::LogLine( "$cmdname aborted by user.\r\n" );
                exit();
                }
            }

        open OUTFILE, ">$output_file" or die "could not open output file:$!";

        return( *OUTFILE{IO} );
        }

    #
    # This function is the start tag handler for the XML parser
    #
    sub __start_tag_handler
        {
        my $expat          = shift;
        my $element_name   = shift;

        my $attributes     = &__array_to_hash( @_ );
#        my @folder_array   = @{$this->{folder_array}};
        my $current_folder = join( ".", @folder_array );

        # outline tag( which includes title or text element )
        if( 'outline' eq $element_name && !$attributes->{htmlUrl} )
            {
            # add folder to array.
            if ( $attributes->{'text'} ) { push @folder_array, $attributes->{'text'}; }
            if ( $attributes->{'title'} ) { push @folder_array, $attributes->{'title'}; }

            $outline_empty = 0;

            my $current_folder = join( ".", @folder_array );

            $opml_parse->{$current_folder} = [];

            return;
            }

        if ( 'outline' eq $element_name && $attributes->{htmlUrl} )
            {
            $outline_empty = 1;
            chomp $attributes->{xmlUrl};
            $attributes->{title} =~ s/\./-/g;
            push @{$opml_parse->{$current_folder}}, $attributes->{xmlUrl};
            }
        }

    #
    # This function is the end tag handler for the XML parser
    #
    sub __end_tag_handler
        {
        my $expat = shift;
        my $element_name = shift;

 #       my @folder_array = @{$this->{folder_array}};

        # if outline end tag
        if( 'outline' eq $element_name && $outline_empty == 0 )
            {
            pop @folder_array;
            @folder_array = \@folder_array;
            $outline_empty = 0;
            return;
            }

        # outline empty tag or other.
        $outline_empty = 0;
        }
    }

1;
