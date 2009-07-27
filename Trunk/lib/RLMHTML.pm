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
# This is the MHTML generator for Rigel, it is
# responsible for:
#     - converting a web page in to a MIME HTML string
#     - retreiving a web page as a text string
#

package RLMHTML;
    {
    use strict;
    use LWP::UserAgent;
    use HTML::TreeBuilder;
    use File::Basename;
    use MIME::Base64;
    use MIME::Types;
    use Exporter;

    our (@ISA, @EXPORT_OK);
    @ISA=qw(Exporter);
    @EXPORT_OK=qw(GetMHTML GetHTML CropBody);

    #
    # This function returns a character string that represents the web page
    # as an MHTML file
    #
    #     RIGELLIB::RLMHTML::GetMHTML(  $url )
    #
    # Where:
    #     $url is the web site to retreive
    #
    sub GetMHTML
        {
        my ( $sitename, $crop_start, $crop_end ) = @_;
        my $result = "";

        # Define the content id for the starting mime part
        my $StartEntry = "<index.html@" . $sitename . ">";

        # Create a cleaned up sitename for use in the content id for the first page
        $StartEntry =~ s/http:\/\///ig;
        $StartEntry =~ s/\//\./ig;

        my $i = 0;
        my $boundry = "_----------=_";

        for( $i = 0; $i < 15; $i++ )
            {
            $boundry .= int( rand( 9 ) );
            }

        $result .= "MIME-Version: 1.0\r\n";
        $result .= "Content-Transfer-Encoding: binary\r\n";
        $result .= "Content-Type: multipart/related; boundary=\"" . $boundry . "\"; start=\"" . $StartEntry . "\"\r\n";
        $result .= "\r\n";
        $result .= "This is a multi-part message in MIME format.\r\n";
        $result .= "\r\n";

        # Boundry entries in the middle are pre-pended with "--"
        $boundry = "--" . $boundry;

        $result .= $boundry . "\r\n";
        $result .= "Content-Disposition: inline; filename=\"index.html\"\r\n";
        $result .= "Content-Id: " . $StartEntry . "\r\n";
        $result .= "Content-Location: " . $sitename . "\r\n";
        $result .= "Content-Transfer-Encoding: 8bit\r\n";
        $result .= "Content-Type: text/html; name=\"index.html\"\r\n";
        $result .= "\r\n";

        my $sitebody = __get_http_body( $sitename );

        $sitebody = CropBody( $sitebody, $crop_start, $crop_end );

        $result .= $sitebody;
        $result .= "\r\n";

        my $mimetypes = MIME::Types->new;
        my $tree = HTML::TreeBuilder->new;
        $tree->parse( $sitebody );

        # Find all the style sheet objects we want to retreive
        my @styles = $tree->find( 'link' );
        my $style = "";

        foreach $style (@styles)
            {
            if( $style->attr( 'rel') eq "stylesheet" )
                {
                my $filename = basename $style->attr( 'href' );
                $result .= $boundry . "\r\n";
                $result .= "Content-Disposition: inline; filename=\"" . $filename . "\"\r\n";
                $result .= "Content-Location: " . __abs_url( $style->attr( 'href' ), $sitename ) . "\r\n";
                $result .= "Content-Transfer-Encoding: 8bit\r\n";
                $result .= "Content-Type: text/html; name=\"" . $filename . "\"\r\n";
                $result .= "\r\n";

                my $itembody = __get_http_body( __abs_url( $style->attr( 'href' ), $sitename ) );
                $result .= $itembody;

                $result .= "\r\n";
                }
            }

        # Find all the img objects we want to retreive
        my @imgs = $tree->find( 'img' );
        my $img = "";

        foreach $img (@imgs)
            {
            my $filename = basename $img->attr( 'src' );
            my $filemimetype = $mimetypes->mimeTypeOf( $filename );

            # in some cases, the 'filename' is really an external link (like ads), in this case we can't determine what kind of image it is going to be, so let's assume it's a jpeg.
            if( !defined( $filemimetype ) ) { $filemimetype = "image/jpeg"; }

            $result .= $boundry . "\r\n";
            $result .= "Content-Disposition: inline; filename=\"" . $filename . "\"\r\n";
            $result .= "Content-Location: " . __abs_url( $img->attr( 'src' ), $sitename ) . "\r\n";
            $result .= "Content-Transfer-Encoding: base64\r\n";

            $result .= "Content-Type: " . $filemimetype . "; name=\"" . $filename . "\"\r\n";
            $result .= "\r\n";

            my $itembody = __get_http_body( __abs_url( $img->attr( 'src' ), $sitename) );
            $result .= encode_base64( $itembody );

            $result .= "\r\n";
            }

        # The last boundry entry is pre and post pended with "--"
        $result .= $boundry . "--\r\n";

        return $result;
        }

    #
    # This function returns a character string that represents the web page
    # as an HTML file
    #
    #     RIGELLIB::RLMHTML::GetHTML(  $url )
    #
    # Where:
    #     $url is the web site to retreive
    #
    sub GetHTML
        {
        my ( $url ) = @_;

        return __get_http_body( $url );
        }

    #
    # This function crops a string at the first occurance of $crop_start and
    # the first occurance of $crop_end after $crop_start.
    #
    #     RIGELLIB::RLMHTML::CropyBody(  $site_body, $crop_start, $crop_end )
    #
    # Where:
    #     $site_body is the string to crop
    #     $crop_start is the starting pattern to crop at (can be regex)
    #     $crop_end is the ending pattern to crop at (can be regex)
    #
    sub CropBody
        {
        my ( $sitebody, $crop_start, $crop_end ) = @_;
        my $junk = "";

        if( $crop_start ne "" )
            {
            ( $junk, $sitebody ) = split( /$crop_start/, $sitebody, 2 );

            # Failsafe, if we didn't match anything, then we should make sure to return the original
            # value.
            if( $sitebody eq "" ) { $sitebody = $junk; }
            }

        if( $crop_end ne "" )
            {
            ( $sitebody, $junk ) = split( /$crop_end/, $sitebody, 2 );
            }

        return $sitebody;
        }

    ###########################################################################
    #  Internal Functions only from here
    ###########################################################################

    #
    # This function returns the absolute URL give a relative url and a base url
    #
    #     __abs_url(  $RelativeURL,  $BaseURL  )
    #
    # Where:
    #     $RelativeURL is the relative url
    #     $BaseURL is the base url
    #
    sub __abs_url
        {
        my ( $relative, $base ) = @_;

        if( $relative =~ m{ \A http:// }ix )
            {
            return $relative;
            }

        my ( $host, $hostrelative_abs ) = $base =~ m{
            \A
            http:// # skip scheme
            ([^/]*) # capture hostname
            /*      # skip front slashes
            (.*?)   # capture everything that follows, but
            [^/]*   # leave out the optional final non-directory component
            \z
        }ix;

        $hostrelative_abs = '' if $relative =~ m!^/!;

        my $abs_url = join '/', $host, $hostrelative_abs, $relative;

        # replace '//' or '/./' with '/'
        1 while $abs_url =~ s{ / \.? (?=/|\z) }{}x;

        # remove '/foo/..' (but be careful to skip '/../..')
        1 while $abs_url =~ s{ / (?!\.\.) [^/]+ / \.\. (?=/|\z) }{}x;

        return "http://$abs_url";
        }

    #
    # This function returns a character string that represents the web page
    # body, it follows redirects as required.
    #
    #     __get_http_body(  $url  )
    #
    # Where:
    #     $url is the web site to retreive
    #
    sub __get_http_body
        {
        my ( $url ) = @_;

        my $ua = LWP::UserAgent->new( requests_redirectable => [ 'GET', 'HEAD', 'POST' ] );
        my $req = HTTP::Request->new( GET => $url );
        my $res = $ua->request( $req );

        return $res->content();
        }
    }


1;
