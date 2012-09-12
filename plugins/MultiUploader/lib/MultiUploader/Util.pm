package MultiUploader::Util;
use strict;
use Exporter;

@MultiUploader::Util::ISA = qw( Exporter );
use vars qw( @EXPORT_OK );
@EXPORT_OK = qw( upload site_path is_writable is_user_can utf8_off );

use MT::Util qw( offset_time_list encode_url decode_url perl_sha1_digest_hex );

use MT::Log;
use MT::FileMgr;
use File::Basename;
use File::Spec;
use Image::Size qw( imgsize );
use Encode;

sub save_asset {
    my ( $app, $blog, $params, $cb ) = @_;
    my $blog_id = $blog->id;
    my $file_path = $params->{ file };
    my $fmgr = $blog->file_mgr;
    unless ( $fmgr->exists( $file_path ) ) {
        return undef;
    }
    my $file = $file_path;
    my $author = $params->{ author };
    my $parent = $params->{ parent };
    $parent = $params->{ parant } unless $parent; # compatible
    $author = current_user( $app ) unless ( defined $author );
    my $label = $params->{ label };
    my $description = $params->{ description };
    my $obj = $params->{ object };
    my $tags = $params->{ tags };
    my $basename = File::Basename::basename( $file_path );
    my $file_ext = file_extension( $file_path );
    my $mime_type = mime_type( $file_path );
    my $class = 'file'; my $is_image;
    require MT::Asset;
    my $asset_pkg = MT::Asset->handler_for_file( $basename );
    my $asset;
    if ( $asset_pkg eq 'MT::Asset::Image' ) {
        $asset_pkg->isa( $asset_pkg );
        $class = 'image';
        $is_image = 1;
    }
    if ( $asset_pkg eq 'MT::Asset::Audio' ) {
        $asset_pkg->isa( $asset_pkg );
        $class = 'audio';
    }
    if ( $asset_pkg eq 'MT::Asset::Video' ) {
        $asset_pkg->isa( $asset_pkg );
        $class = 'video';
    }
    unless ( defined $author ) {
        if ( $parent ) {
            my $parent_asset = $asset_pkg->load( { id => $parent } );
            if ( $parent_asset ) {
                $author = MT::Author->load( $parent_asset->created_by );
            }
        }
        $author = MT::Author->load( undef, { limit => 1 } ) unless ( defined $author );
    }
    my $url = $file_path;
    $url =~ s!\\!/!g if is_windows();
    $url = path2url( $url, $blog, 1 );
    $url = path2relative( $url, $blog, 1 );
    $file_path = path2relative( $file_path, $blog, 1 );
    $asset = $asset_pkg->load( { blog_id => $blog_id,
                                 file_path => $file_path } );
    my $original;
    unless ( $asset ) {
        $asset = $asset_pkg->new();
    } else {
        $original = $asset->clone();
    }
    $original = $asset->clone();
    $asset->blog_id( $blog_id );
    $asset->url( $url );
    $asset->file_path( $file_path );
    $asset->file_name( $basename );
    $asset->mime_type( $mime_type );
    $asset->file_ext( $file_ext );
    $asset->class( $class );
    $asset->created_by( $author->id );
    $asset->modified_by( $author->id );
    if ( $parent ) {
        $asset->parent( $parent );
    }
    my ( $w, $h, $id );
    if ( $class eq 'image' ) {
        require Image::Size;
        ( $w, $h, $id ) = Image::Size::imgsize( $file );
        $asset->image_width( $w );
        $asset->image_height( $h );
    }
    unless ( $label ) {
        $label = file_label( $basename );
    }
    $asset->label( $label );
    if ( $description ) {
        $asset->description( $description );
    }
    if ( $cb ) {
        $app->run_callbacks( 'cms_pre_save.asset', $app, $asset, $original )
          || return $app->errtrans( "Saving [_1] failed: [_2]", 'asset',
            $app->errstr );
    }
    $asset->set_tags( @$tags );
    $asset->save or die $asset->errstr;
    if ( $cb ) {
        $app->run_callbacks( 'cms_post_save.asset', $app, $asset, $original );
    } else {
        $app->log(
            {
                message => $app->translate(
                    "File '[_1]' uploaded by '[_2]'", $asset->file_name,
                    $author->name,
                ),
                level    => MT::Log::INFO(),
                class    => 'asset',
                blog_id  => $blog_id,
                category => 'new',
            }
        );
    }
    # my @fstats = stat( $file );
    # my $bytes = $fstats[7];
    if ( $obj ) {
        if ( $obj->id ) {
            require MT::ObjectAsset;
            my $object_asset = MT::ObjectAsset->get_by_key( {
                                                              blog_id => $obj->blog_id,
                                                              asset_id => $asset->id,
                                                              object_id => $obj->id,
                                                              object_ds => $obj->datasource,
                                                            } );
            unless ( $object_asset->id ) {
                $object_asset->save or die $object_asset->errstr;
            }
        }
    }
    my $res = upload_callback( $app, $blog, $asset, $id ) if $cb;
    return $asset;
}

sub is_writable {
    my ( $path, $blog ) = @_;
    my $app = MT->instance();
    $path = File::Spec->canonpath( $path );
    my $tempdir = quotemeta( $app->config( 'TempDir' ) );
    my $importdir = quotemeta( $app->config( 'ImportPath' ) );
    my $support_dir = quotemeta( support_dir() );
    if ( $path =~ /\A(?:$tempdir|$importdir|$support_dir)/ ) {
        return 1;
    }
    if ( defined $blog ) {
        my $site_path = quotemeta( site_path( $blog ) );
        if ( $path =~ /^$site_path/ ) {
            return 1;
        }
    }
    return 0;
}

sub upload {
    my ( $app, $blog, $name, $dir, $params ) = @_;
    my $limit = $app->config( 'CGIMaxUpload' ) || 20480000;
    $app->validate_magic() or return 0;
    return 0 unless $app->can_do( 'upload' );
    return 0 unless $blog;
#    my %params = ( object => $obj,
#                   author => $author,
#                   rename => 1,
#                   label => 'foo',
#                   description => 'bar',
#                   format_LF => 1,
#                   singler => 1,
#                   no_asset => 1,
#                   );
#    my $upload = upload( $app, $blog, $name, $dir, \%params );

    my $obj = $params->{ object };
    my $rename = $params->{ 'rename' };
    my $label = $params->{ label };
    my $format_LF = $params->{ format_LF };
    my $singler = $params->{ singler };
    my $no_asset = $params->{ no_asset };
    my $description = $params->{ description };
    my $force_decode_filename = $params->{ force_decode_filename };
    my $no_decode = $app->config( 'NoDecodeFilename' );
    if (! $force_decode_filename ) {
        if ( $no_decode ) {
            $force_decode_filename = 1;
        }
    }
    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
    my $q = $app->param;
    my @files = $q->upload( $name );
    my @assets;
    my $upload_total;
    for my $file ( @files ) {
        my $size = ( -s $file );
        $upload_total = $upload_total + $size;
        if ( $limit < $upload_total ) {
            return ( undef, 1 ); # Upload file size over CGIMaxUpload;
        }
    }
    for my $file ( @files ) {
        my $orig_filename = file_basename( $file );
        my $basename = $orig_filename;
        $basename =~ s/%2E/\./g;
        $basename = encode_url( $basename );
        $basename =~ s!\\!/!g;    ## Change backslashes to forward slashes
        $basename =~ s!^.*/!!;    ## Get rid of full directory paths
        if ( $basename =~ m!\.\.|\0|\|! ) {
            return ( undef, 1 );
        }
        $basename
            = Encode::is_utf8( $basename )
            ? $basename
            : Encode::decode( $app->charset,
            File::Basename::basename( $basename ) );
        if ( my $deny_exts = $app->config->DeniedAssetFileExtensions ) {
            my @deny_exts = map {
                if   ( $_ =~ m/^\./ ) {qr/$_/i}
                else                  {qr/\.$_/i}
            } split '\s?,\s?', $deny_exts;
            my @ret = File::Basename::fileparse( $basename, @deny_exts );
            if ( $ret[2] ) {
                return ( undef, 1 );
            }
        }
        if ( my $allow_exts = $app->config( 'AssetFileExtensions' ) ) {
            my @allow_exts = map {
                if   ( $_ =~ m/^\./ ) {qr/$_/i}
                else                  {qr/\.$_/i}
            } split '\s?,\s?', $allow_exts;
            my @ret = File::Basename::fileparse( $basename, @allow_exts );
            unless ( $ret[2] ) {
                return ( undef, 1 );
            }
        }
        $orig_filename = $basename;
        $orig_filename = encode_url( $orig_filename ) if $force_decode_filename;
        my $file_label = file_label( $orig_filename );
        if (! $no_decode ) {
            $orig_filename = set_upload_filename( $orig_filename );
        }
        my $out = File::Spec->catfile( $dir, $orig_filename );
        if ( $rename ) {
            $out = uniq_filename( $out );
        }
        $dir =~ s!/$!! unless $dir eq '/';
        if (! is_writable( $dir, $blog ) ) {
            return ( undef, 1 );
        }
        unless ( $fmgr->exists( $dir ) ) {
            $fmgr->mkpath( $dir ) or return MT->trans_error( "Error making path '[_1]': [_2]",
                                    $out, $fmgr->errstr );
        }
        my $temp = "$out.new";
        my $umask = $app->config( 'UploadUmask' );
        my $old = umask( oct $umask );
        open ( my $fh, ">$temp" ) or die "Can't open $temp!";
        if ( is_image( $file ) ) {
            require MT::Image;
            if (! MT::Image::is_valid_image( $fh ) ) {
                close ( $fh );
                next;
            }
        }
        binmode ( $fh );
        while( read ( $file, my $buffer, 1024 ) ) {
            $buffer = format_LF( $buffer ) if $format_LF;
            print $fh $buffer;
        }
        close ( $fh );
        $fmgr->rename( $temp, $out );
        umask( $old );
        my $user = $params->{ author };
        $user = current_user( $app ) unless defined $user;
        if ( $no_asset ) {
            if ( $singler ) {
                return $out;
            }
            push ( @assets, $out );
        } else {
            if ( ( $user ) && ( $blog ) ) {
                my %params = ( file => $out,
                               author => $user,
                               label => ( $label || $file_label ),
                               description => $description,
                               object => $obj,
                               );
                my $asset = save_asset( $app, $blog, \%params, 1 ) or die;
                if ( $singler ) {
                    return $asset;
                }
                push ( @assets, $asset ) if defined $asset;
            }
        }
    }
    return \@assets;
}

sub write2file {
    my ( $path, $data, $type, $blog ) = @_;
    my $fmgr = MT::FileMgr->new( 'Local' ) or return 0; # die MT::FileMgr->errstr;
    if ( $blog ) {
        $path = relative2path( $path, $blog );
    }
    my $dir = dirname( $path );
    $dir =~ s!/$!! unless $dir eq '/';
    unless ( $fmgr->exists( $dir ) ) {
        $fmgr->mkpath( $dir ) or return 0; # MT->trans_error( "Error making path '[_1]': [_2]",
                                # $path, $fmgr->errstr );
    }
    $fmgr->put_data( $data, "$path.new", $type );
    if ( $fmgr->rename( "$path.new", $path ) ) {
        if ( $fmgr->exists( $path ) ) {
            return 1;
        }
    }
    return 0;
}

sub read_from_file {
    my ( $path, $type, $blog ) = @_;
    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
    if ( $blog ) {
        $path = relative2path( $path, $blog );
    }
    unless ( $fmgr->exists( $path ) ) {
       return '';
    }
    my $data = $fmgr->get_data( $path, $type );
    return $data;
}

sub relative2path {
    my ( $path, $blog ) = @_;
    my $app = MT->instance();
    my $static_file_path = static_or_support();
    my $archive_path = archive_path( $blog );
    my $site_path = site_path( $blog );
    $path =~ s/%s/$static_file_path/;
    $path =~ s/%r/$site_path/;
    if ( $archive_path ) {
        $path =~ s/%a/$archive_path/;
    }
    return $path;
}

sub path2relative {
    my ( $path, $blog, $exclude_archive_path ) = @_;
    my $app = MT->instance();
    my $static_file_path = quotemeta( static_or_support() );
    my $archive_path = quotemeta( archive_path( $blog ) );
    my $site_path = quotemeta( site_path( $blog, $exclude_archive_path ) );
    $path =~ s/$static_file_path/%s/;
    $path =~ s/$site_path/%r/;
    if ( $archive_path ) {
        $path =~ s/$archive_path/%a/;
    }
    if ( $path =~ m!^https{0,1}://! ) {
        my $site_url = quotemeta( site_url( $blog ) );
        $path =~ s/$site_url/%r/;
    }
    return $path;
}

sub static_or_support {
    my $app = MT->instance();
    my $static_or_support;
    if ( MT->version_number < 5 ) {
        $static_or_support = $app->static_file_path;
    } else {
        $static_or_support = $app->support_directory_path;
    }
    return $static_or_support;
}

sub support_dir {
    my $app = MT->instance();
    my $support_dir;
    if ( MT->version_number < 5 ) {
        $support_dir = File::Spec->catdir( $app->static_file_path, 'support' );
    } else {
        $support_dir = $app->support_directory_path;
    }
    return $support_dir;
}

sub path2url {
    my ( $path, $blog, $exclude_archive_path ) = @_;
    my $site_path = quotemeta ( site_path( $blog, $exclude_archive_path ) );
    my $site_url = site_url( $blog );
    $path =~ s/^$site_path/$site_url/;
    if ( is_windows() ) {
        $path =~ s!/!\\!g;
    }
    return $path;
}

sub relative2url {
    my ( $path, $blog ) = @_;
    return path2url( relative2path( $path,$blog ), $blog );
}

sub url2path {
    my ( $url, $blog ) = @_;
    my $site_url = quotemeta ( site_url( $blog ) );
    my $site_path = site_path( $blog );
    $url =~ s/^$site_url/$site_path/;
    if ( is_windows() ) {
        $url =~ s!/!\\!g;
    }
    return $url;
}

sub site_path {
    my ( $blog, $exclude_archive_path ) = @_;
    my $site_path;
    unless ( $exclude_archive_path ) {
        $site_path = $blog->archive_path;
    }
    $site_path = $blog->site_path unless $site_path;
    return chomp_dir( $site_path );
}

sub archive_path {
    my $blog = shift;
    my $archive_path = $blog->archive_path;
    return chomp_dir( $archive_path );
}

sub site_url {
    my $blog = shift;
    my $site_url = $blog->site_url;
    $site_url =~ s{/+$}{};
    return $site_url;
}

sub current_ts {
    my $blog = shift;
    my @tl = offset_time_list( time, $blog );
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $tl[5]+1900, $tl[4]+1, @tl[3,2,1,0];
    return $ts;
}

sub current_user {
    my $app = shift || MT->instance();
    my $user;
    eval { $user = $app->user };
    unless ( $@ ) {
        return $user if defined $user;
    }
    return undef;
}

sub set_upload_filename {
    my $file = shift;
    $file = File::Basename::basename( $file );
    my $ctext = encode_url( $file );
    if ( $ctext ne $file ) {
        unless ( MT->version_number < 5 ) {
            $file = utf8_off( $file );
        }
        my $extension = file_extension( $file );
        my $ext_len = length( $extension ) + 1;
        if ( eval { require Digest::MD5 } ) {
            $file = Digest::MD5::md5_hex( $file );
        } else {
            $file = perl_sha1_digest_hex( $file );
        }
        $file = substr ( $file, 0, 255 - $ext_len );
        $file .= '.' . $extension;
    }
    return $file;
}

sub uniq_filename {
    my $file = shift;
    require File::Basename;
    my $no_decode = MT->config( 'NoDecodeFilename' );
    my $dir = File::Basename::dirname( $file );
    my $tilda = quotemeta( '%7E' );
    $file =~ s/$tilda//g;
    if ( $no_decode ) {
        $file = File::Spec->catfile( $dir, $file );
    } else {
        $file = File::Spec->catfile( $dir, set_upload_filename( $file ) );
    }
    return $file unless ( -f $file );
    my $file_extension = file_extension( $file );
    my $base = $file;
    $base =~ s/(.{1,})\.$file_extension$/$1/;
    $base = $1 if ( $base =~ /(^.*)_[0-9]{1,}$/ );
    my $i = 0;
    do { $i++;
         $file = $base . '_' . $i . '.' . $file_extension;
       } while ( -e $file );
    return $file;
}

sub format_LF {
    my $data = shift;
    $data =~ s/\r\n?/\n/g;
    return $data;
}

sub is_user_can {
    my ( $blog, $user, $permission ) = @_;
    $permission = 'can_' . $permission;
    my $perm = $user->is_superuser;
    unless ( $perm ) {
        if ( $blog ) {
            my $admin = 'can_administer_blog';
            $perm = $user->permissions( $blog->id )->$admin;
            $perm = $user->permissions( $blog->id )->$permission unless $perm;
        } else {
            $perm = $user->permissions()->$permission;
        }
    }
    return $perm;
}

sub is_application {
    my $app = shift || MT->instance();
    return (ref $app) =~ /^MT::App::/ ? 1 : 0;
}

sub is_cms {
    my $app = shift || MT->instance();
    return ( ref $app eq 'MT::App::CMS' ) ? 1 : 0;
}

sub is_windows { $^O eq 'MSWin32' ? 1 : 0 }

sub file_extension {
    my ( $file, $nolc ) = @_;
    my $extension = '';
    if ( $file =~ /\.([^.]+)\z/ ) {
        $extension = $1;
        $extension = lc( $extension ) unless $nolc;
    }
    return $extension;
}

sub file_label {
    my $file = shift;
    $file = file_basename( $file );
    my $file_extension = file_extension( $file, 1 );
    my $base = $file;
    $base =~ s/(.{1,})\.$file_extension$/$1/;
    $base = Encode::decode_utf8( $base ) unless Encode::is_utf8( $base );
    return $base;
}

sub file_basename {
    my $file = shift;
    if ( !is_windows() && $file =~ m/\\/ ) { # Windows Style Path on Not-Win
        my $prev = File::Basename::fileparse_set_fstype( 'MSWin32' );
        $file = File::Basename::basename( $file );
        File::Basename::fileparse_set_fstype( $prev );
    } else {
        $file = File::Basename::basename( $file );
    }
    return $file;
}

sub mime_type {
    my $file = shift;
    my %mime_type = (
        'css'   => 'text/css',
        'html'  => 'text/html',
        'mtml'  => 'text/html',
        'xhtml' => 'application/xhtml+xml',
        'htm'   => 'text/html',
        'txt'   => 'text/plain',
        'rtx'   => 'text/richtext',
        'tsv'   => 'text/tab-separated-values',
        'csv'   => 'text/csv',
        'hdml'  => 'text/x-hdml; charset=Shift_JIS',
        'xml'   => 'application/xml',
        'atom'  => 'application/atom+xml',
        'rss'   => 'application/rss+xml',
        'rdf'   => 'application/rdf+xml',
        'xsl'   => 'text/xsl',
        'mpeg'  => 'video/mpeg',
        'mpg'   => 'video/mpeg',
        'mpe'   => 'video/mpeg',
        'qt'    => 'video/quicktime',
        'avi'   => 'video/x-msvideo',
        'movie' => 'video/x-sgi-movie',
        'mov'   => 'video/quicktime',
        'ice'   => 'x-conference/x-cooltalk',
        'svr'   => 'x-world/x-svr',
        'vrml'  => 'x-world/x-vrml',
        'wrl'   => 'x-world/x-vrml',
        'vrt'   => 'x-world/x-vrt',
        'spl'   => 'application/futuresplash',
        'js'    => 'application/javascript',
        'json'  => 'application/json',
        'hqx'   => 'application/mac-binhex40',
        'doc'   => 'application/msword',
        'pdf'   => 'application/pdf',
        'ai'    => 'application/postscript',
        'eps'   => 'application/postscript',
        'ps'    => 'application/postscript',
        'rtf'   => 'application/rtf',
        'ppt'   => 'application/vnd.ms-powerpoint',
        'xls'   => 'application/vnd.ms-excel',
        'dcr'   => 'application/x-director',
        'dir'   => 'application/x-director',
        'dxr'   => 'application/x-director',
        'dvi'   => 'application/x-dvi',
        'gtar'  => 'application/x-gtar',
        'gzip'  => 'application/x-gzip',
        'latex' => 'application/x-latex',
        'lzh'   => 'application/x-lha',
        'swf'   => 'application/x-shockwave-flash',
        'sit'   => 'application/x-stuffit',
        'tar'   => 'application/x-tar',
        'tcl'   => 'application/x-tcl',
        'tex'   => 'application/x-texinfo',
        'texinfo'=>'application/x-texinfo',
        'texi'  => 'application/x-texi',
        'src'   => 'application/x-wais-source',
        'zip'   => 'application/zip',
        'au'    => 'audio/basic',
        'snd'   => 'audio/basic',
        'midi'  => 'audio/midi',
        'mid'   => 'audio/midi',
        'kar'   => 'audio/midi',
        'mpga'  => 'audio/mpeg',
        'mp2'   => 'audio/mpeg',
        'mp3'   => 'audio/mpeg',
        'ra'    => 'audio/x-pn-realaudio',
        'ram'   => 'audio/x-pn-realaudio',
        'rm'    => 'audio/x-pn-realaudio',
        'rpm'   => 'audio/x-pn-realaudio-plugin',
        'wav'   => 'audio/x-wav',
        'bmp'   => 'image/x-ms-bmp',
        'gif'   => 'image/gif',
        'jpeg'  => 'image/jpeg',
        'jpg'   => 'image/jpeg',
        'jpe'   => 'image/jpeg',
        'png'   => 'image/png',
        'tiff'  => 'image/tiff',
        'tif'   => 'image/tiff',
        'ico'   => 'image/vnd.microsoft.icon',
        'pnm'   => 'image/x-portable-anymap',
        'ras'   => 'image/x-cmu-raster',
        'pnm'   => 'image/x-portable-anymap',
        'pbm'   => 'image/x-portable-bitmap',
        'pgm'   => 'image/x-portable-graymap',
        'ppm'   => 'image/x-portable-pixmap',
        'rgb'   => 'image/x-rgb',
        'xbm'   => 'image/x-xbitmap',
        'xpm'   => 'image/x-pixmap',
        'xwd'   => 'image/x-xwindowdump',
    );
    my $extension = file_extension( $file );
    my $type = $mime_type{ $extension };
    $type = 'text/plain' unless $type;
    return $type;
}

sub upload_callback {
    my ( $app, $blog, $asset, $id ) = @_;
    my $file = $asset->file_path;
    my @fstats = stat( $file );
    my $bytes = $fstats[7];
    my $url = $asset->url;
    $app->run_callbacks(
        'cms_upload_file.' . $asset->class,
        File  => $file,
        file  => $file,
        Url   => $url,
        url   => $url,
        Size  => $bytes,
        size  => $bytes,
        Asset => $asset,
        asset => $asset,
        Type  => $asset->class,
        type  => $asset->class,
        Blog  => $blog,
        blog  => $blog
    );
    if ( $asset->class eq 'image' ) {
        unless ( $id ) {
            my ( $w, $h );
            ( $w, $h, $id ) = imgsize( $file );
        }
        $app->run_callbacks(
            'cms_upload_image',
            File       => $file,
            file       => $file,
            Url        => $url,
            url        => $url,
            Size       => $bytes,
            size       => $bytes,
            Asset      => $asset,
            asset      => $asset,
            Height     => $asset->image_height,
            height     => $asset->image_height,
            Width      => $asset->image_width,
            width      => $asset->image_width,
            Type       => 'image',
            type       => 'image',
            ImageType  => $id,
            image_type => $id,
            Blog       => $blog,
            blog       => $blog
        );
    }
    return 1;
}

sub chomp_dir {
    my $dir = shift;
    my @path = File::Spec->splitdir( $dir );
    $dir = File::Spec->catdir( @path );
    return $dir;
}

sub add_slash {
    my ( $path, $os ) = @_;
    return $path if $path eq '/';
    if ( $path =~ m!^https?://! ) {
        $path =~ s{/*\z}{/};
        return $path;
    }
    $path = chomp_dir( $path );
    my $windows;
    if ( $os ) {
        if ( $os eq 'windows' ) {
            $windows = 1;
        }
    } else {
        if ( is_windows() ) {
            $windows = 1;
        }
    }
    if ( $windows ) {
        $path .= '\\';
    } else {
        $path .= '/';
    }
    return $path;
}

sub create_thumbnail {
    my ( $blog, $asset, %param ) = @_;
    my $app = MT->instance();
    my ( $thumb, $w, $h );
    my $orig_update = ( stat( $asset->file_path ) )[9];
    $thumb = File::Spec->catfile( $asset->_make_cache_path( $param{ Path } ),
                                  $asset->thumbnail_filename( %param ) );
    my $is_new; my $new_thumb;
    if (-f $thumb ) {
        my $thumb_update = ( stat( $thumb ) )[9];
        if ( $thumb_update < $orig_update ) {
            unlink $thumb;
            $is_new = 1;
            $new_thumb = convert_gif_png( $thumb );
            unlink $new_thumb if (-f $new_thumb );
        }
    } else {
        $is_new = 1;
    }
    ( $thumb, $w, $h ) = $asset->thumbnail_file( %param );
    if ( $is_new ) {
        my %params = ( file   => $thumb,
                       label  => $asset->label,
                       parent => $asset->id,
                      );
        my $asset = save_asset( $app, $blog, \%params );
        $new_thumb = convert_gif_png( $thumb );
        if (-f $new_thumb ) {
            $params{ file } = $new_thumb;
            save_asset( $app, $blog, \%params );
        }
    }
    return ( $thumb, $w, $h );
}

sub utf8_off {
    my $text = shift;
    return MT::I18N::utf8_off( $text );
}

sub is_image {
    my $file = shift;
    my $basename = File::Basename::basename( $file );
    require MT::Asset;
    my $asset_pkg = MT::Asset->handler_for_file( $basename );
    if ( $asset_pkg eq 'MT::Asset::Image' ) {
        return 1;
    }
    return 0;
}

1;