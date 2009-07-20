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

package RIGELLIB::Config;
    {
    use strict;
    use Encode;
    use XML::Parser;
    use XML::Parser::Expat;
    use XML::FeedPP;
    use Getopt::Long;
    use RIGELLIB::Common;
    use RIGELLIB::Unicode;
    use RIGELLIB::Debug;

    our $this = undef;

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
        };

    # opml parse result.
    our $opml_parse = undef;

    our $debug = undef;

    sub new
        {
        my $pkg_name  = shift;
        my @folder_name = ();

        # First, parse the commnad line in case the config file location is specified
        &__parse_options();

        # Config value initialize.
        &__parse_conf();

        # Now reparse the command line to override and config values set above
        &__parse_options();

        $debug = RIGELLIB::Debug->new( \%{$DEFAULT_GLOBAL_CONFIG} );

        $debug->OutputDebug( 2, "Global Config Dump:", \%{$DEFAULT_GLOBAL_CONFIG} );
        $debug->OutputDebug( 2, "Site Config Dump:",  \%{$DEFAULT_SITE_CONFIG} );

        $this = bless
            {
            folder_array   => \@folder_name,
            outline_empty  => 0,
            }, $pkg_name;

        return $this;
        }

    sub start_tag_handler
        {
        my $expat          = shift;
        my $element_name   = shift;

        my $attributes     = &__array_to_hash( @_ );
        my @folder_array   = @{$this->{folder_array}};
        my $current_folder = join( ".", @folder_array );

        # outline tag( which includes title or text element )
        if( 'outline' eq $element_name && !$attributes->{htmlUrl} )
            {
            # add folder to array.
            if ( $attributes->{'text'} ) { push @folder_array, $attributes->{'text'}; }
            if ( $attributes->{'title'} ) { push @folder_array, $attributes->{'title'}; }

            $this->{folder_array} = \@folder_array;
            $this->{outline_empty} = 0;

            my $current_folder = join( ".", @folder_array );

            $opml_parse->{$current_folder} = [];

            return;
            }

        if ( 'outline' eq $element_name && $attributes->{htmlUrl} )
            {
            $this->{outline_empty} = 1;
            chomp $attributes->{xmlUrl};
            $attributes->{title} =~ s/\./-/g;
            push @{$opml_parse->{$current_folder}}, $attributes->{xmlUrl};
            }
        }

    sub end_tag_handler
        {
        my $expat = shift;
        my $element_name = shift;

        my @folder_array = @{$this->{folder_array}};

        # if outline end tag
        if( 'outline' eq $element_name && $this->{outline_empty} == 0 )
            {
            pop @folder_array;
            $this->{folder_array} = \@folder_array;
            $this->{outline_empty} = 0;
            return;
            }

        # outline empty tag or other.
        $this->{outline_empty} = 0;
        }

    sub import_file
        {
        my $this = shift;
        my $filename = shift;

        my $output_file = $this->get_global_conf( 'outfile' );

        # parameter check.
        if( !defined $filename )
            {
            print "import : you should spefify opml filename after [-I|--import] option.\n";
            }

        if( !defined $output_file )
            {
            print "import : you should spefify output filename after [-O] option.\n";
            }

        if( !defined $filename || !defined $output_file )
            {
            print "Usage: ./Rigel [-I|--import] [opml filename] -O [site filename].\n";
            exit();
            }

        if( !$filename || !(-e $filename) )
            {
            print "import: File does not exist : $filename\n";
            exit();
            }

        my $parser = new XML::Parser(
                            Handlers => {
                                Start => \&start_tag_handler,
                                End   => \&end_tag_handler,
                            }
                     );

        $opml_parse = {};

        print "parsing opml file...: $filename\n";

        # parse opml file.
        eval{ $parser->parsefile( $filename ); };

        if ($@ )
            {
            print "import process failed : $@";
            exit();
            }

        # output result here.
        $this->__print_config_file( $output_file );

        print "finished generating site file successfully -> $output_file\n";
        exit();
        }

    sub parse_url_list
        {
        my $this = shift;
        my @filenames =  shift;

        my %config = %{$DEFAULT_SITE_CONFIG};
        my @config_list;

        for my $filename (@filenames)
            {
            open( F, $filename ) || die "$! : $filename\n";

            while( <F> )
                {
                chomp;
                s/\s*$//;
                if( /^(ftp|http|https):\/\// )
                    {
                    push @{$config{url}}, $_;
                    }
                elsif( /^\#/ )
                    {
                    }
                elsif( /^([^:]+)\s*:\s*(.*)\s*/ )
                    {
                    my $key   = &__trim( lc( $1 ) );
                    my $value = &__trim( $2 );

                    if( !exists $config{$key} )
                        {
                        print "WARNING: key value [$1] is undefined!\n";
                        next;
                        }

                    if( $key =~ /(expire-unseen|sync)/ && $2 =~ /^(no|0)$/i )
                        {
                        next;
                        }

                    $config{$key} = RIGELLIB::Unicode::to_utf8( $value );
                    }
                elsif( /^\s*$/ )
                    {
                    if (keys %config) { push @config_list, { %config }; }
                    %config = %{$DEFAULT_SITE_CONFIG};
                    }
                else
                    {
                    print "WARNING: parse error $_\n";
                    }
                }

            close( F );
            if (keys %config) { push @config_list, { %config }; }
            }

        return \@config_list;
        }

    sub parse_url_list_from_string()
        {
        my $this     = shift;
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
                push @{$config{url}}, __trim( $_ );
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
                my $key   = &__trim( lc( $1 ) );
                my $value = &__trim( $2 );

                if( !exists $config{$key} )
                    {
                    print "WARNING: key value [$1] is undefined!\n";
                    next;
                    }

                if ($key =~ /(expire-unseen|sync)/ && $2 =~ /^(no|0)$/i )
                    {
                    next;
                    }

                $config{$key} = RIGELLIB::Unicode::to_utf8( $value );
                $debug->OutputDebug( 2, "config{$key} = $value\r\n" );
                }
            else
                {
                print "WARNING: parse error $_\n";
                }
            }

        return %config;
        }

    sub export_file
        {
        my $this        = shift;
        my @filenames   = shift;

        my $output_file = $this->get_global_conf( 'outfile' );

        # parameter check.
        if( !@filenames || !defined $filenames[0] )
            {
            print "export : you should spefify site filename after [-E|--export] option.\n";
            }

        if( !defined $output_file )
            {
            print "export : you should spefify output file with [-O] option.\n";
            }

        if( !defined $filenames[0] || !defined $output_file )
            {
            print "Usage: ./Rigel [-E|--export] [site filename] -O [opml filename].\n";
            exit();
            }

        # get proxy pass if enabled
        my $common = RIGELLIB::Common->new( \%{$DEFAULT_GLOBAL_CONFIG} );
        $common->getProxyPass_ifEnabled();

        # open output file. if output file exists, ask if overwrite it.
        my ($out_fh) = &__find_and_ask( 'export', $output_file, 0 );

        # get config list.
        # this array is composed of ${DEFAULT_SITE_CONFIG}
        # which value is overridden by url list.
        print "export: parsing site file...\n";
        my @config_list = @{$this->parse_url_list( @filenames )};

        # sort array by 'folder' key.
        @config_list = &__sort_array_byfolder( @config_list );
        if( scalar(@config_list) == 0 )
            {
            print "No configuration found from your site file.\n";
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
                print "processing $link ....\n";
                my $common = RIGELLIB::Common->new( \%{$DEFAULT_GLOBAL_CONFIG} );
                my @rss_and_response = $common->getrss_and_response( $link, {} );

                if ( scalar(@rss_and_response) == 0 )
                    {
                    next;
                    }

                my $content = $rss_and_response[0];
                my $rss = undef;

                eval { $rss = XML::FeedPP->new( $content ); };

                if( $@ )
                    {
                    print "WARNING: feed error, skip this url...\n";
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

        print "finished generating opml file successfully -> $output_file\n";
        exit();
        }

    sub get_global_conf
        {
        my $this = shift;
        my $key  = shift;

        return $DEFAULT_GLOBAL_CONFIG->{$key};
        }

    sub get_site_conf
        {
        my $this = shift;
        my $key  = shift;

        return $DEFAULT_SITE_CONFIG->{$key};
        }

    sub get_version
        {
        return $VERSION;
        }

    sub get_global_configall
        {
        return $DEFAULT_GLOBAL_CONFIG;
        }

    sub get_site_configall
        {
        return $DEFAULT_SITE_CONFIG;
        }

    ######################################
    #
    #    from here, private subroutine.
    #
    ######################################

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

    sub __parse_conf {
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

    sub __parse_conffile
        {
        my $filename   = shift;
        my %return_hash = ();

        open( CONFFILE, $filename ) or die "$filename:Could not open configfile:$!\n";

        while( my $line = <CONFFILE>)
            {
            if ( $line =~ /^#/ || $line =~ /^$/ )
                {
                next;
                }

            my ($config_key, $value ) = split /=/, $line;

            $config_key = &__trim( $config_key );
            $value      = &__trim( $value );
            $value = undef if ($value eq "undef" || $value eq "" || $value eq "no" );
            $return_hash{$config_key} = $value;
            }

        return %return_hash;
        }

    sub __parse_options
        {
        my @ARGV_TMP = @ARGV;

        Getopt::Long::config( 'bundling' );
        Getopt::Long::GetOptions(
                   's|host=s'                      => \$DEFAULT_GLOBAL_CONFIG->{'host'},
                   'u|user=s'                      => \$DEFAULT_GLOBAL_CONFIG->{'user'},
                   'P|port=s'                      => \$DEFAULT_GLOBAL_CONFIG->{'port'},
                   'm|last-modified-folder=s'     => \$DEFAULT_GLOBAL_CONFIG->{'last-modified-folder'},
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

    sub __trim()
        {
        my $str = shift;

        if( !defined $str )
            {
            return undef;
            }

        chomp $str;
        $str =~ s/^\s*//;
        $str =~ s/\s*$//;

        return $str;
        }

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

    sub __print_config_file()
        {
        my $this        = shift;
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
                print $out_fh RIGELLIB::Unicode::to_utf8( "$xml_uri\n" );
                }

            print $out_fh "\n";
            }
        }

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

        $debug->OutputDebug( 2, "Array Dump:", \@key_array );

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

    sub __find_and_ask()
        {
        my $cmdname     = shift;
        my $output_file = shift;
        my $can_append  = shift;

        # ask if overwrite, append, or abort.
        if( -e $output_file && $can_append )
            {
            print "\n$output_file already exists! overwrite?[O], append?[A], or exit?[E] (O/A/E):";
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
                print "$cmdname aborted by user.\n";
                exit();
                }
            }

        if( -e $output_file && !$can_append )
            {
            print "\n$output_file already exists! overwrite? (y/N):";
            my $answer = <STDIN>;
            chomp $answer;

            if( $answer =~ /Y/i )
                {
                open OUTFILE, ">$output_file" or die "could not open output file:$!";
                return( *OUTFILE{IO} );
                }
            else
                {
                print "$cmdname aborted by user.\n";
                exit();
                }
            }

        open OUTFILE, ">$output_file" or die "could not open output file:$!";

        return( *OUTFILE{IO} );
        }
    }

1;
