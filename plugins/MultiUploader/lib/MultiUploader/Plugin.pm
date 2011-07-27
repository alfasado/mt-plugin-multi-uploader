package MultiUploader::Plugin;

use strict;
use MT::Asset;
use MultiUploader::Util qw( upload site_path is_writable is_user_can );

sub _upload_multi {
    my $app = shift;
    my $blog = $app->blog;
    my $site_path = site_path( $blog, 1 );
    if (! $blog ) {
        return MT->translate( 'Invalid request.' );
    }
    $app->validate_magic() or return MT->translate( 'Permission denied.' );
    my $user = $app->user;
    if (! is_user_can( $blog, $user, 'upload' ) ) {
        return MT->translate( 'Permission denied.' );
    }
    my $middle_path = $app->param( 'middle_path' );
    $middle_path =~ s!^/!!;
    $middle_path =~ s!\.\.!!g;
    my $upload_dir = File::Spec->catdir( $site_path, $middle_path );
    if (! is_writable( $upload_dir, $blog ) ) {
        return MT->translate( 'Invalid request.' );
    }
    my ( $res, $err ) = upload (
        $app, $blog, 'file', $upload_dir, { rename => 1, force_decode_filename => 1, singler => 1 }, 1
    );
    if ( $res ) {
        my $type = $res->mime_type;
        my $name = $res->url;
        require MT::FileMgr;
        my $fmgr = MT::FileMgr->new( 'Local' );
        my $size = $fmgr->file_size( $res->file_path );
        return '{"name":"' . $name . '","type":"' . $type . '","size":"' . $size . '"}';
    } else {
        my $name = $app->translate( 'An error occurred' );
        my $type = '';
        my $size = 0;
        return '{"name":"' . $name . '","type":"' . $type . '","size":"' . $size . '"}';
    }
}

sub _tmpl_output {
    my ( $cb, $app, $tmpl ) = @_;
    if ( $app->param( '_type' ) ne 'multiuploader' ) {
        return;
    }
    if ( $$tmpl =~ m!</head>! ) {
        my $static_path = $app->static_path;
        my $old_jq = quotemeta( '<script type="text/javascript" src="' . $static_path . 'jquery/jquery.min.js' );
        my $new_jq = '<script src="' . $static_path . 'plugins/MultiUploader/jquery-1.5.1.min.js"></script>';
        $$tmpl =~ s!$old_jq.*?</script>!$new_jq!;
        my $current_magic = $app->current_magic;
        my $blog = $app->blog;
        my $blog_id = $blog->id;
        my $action = $app->path . $app->script;
        my $plugin = MT->component( 'MultiUploader' );
        my $get_from = 'blog:'. $blog->id;
        my $upload_path = $plugin->get_config_value( 'upload_path', $get_from );
        my $label = $plugin->translate( 'Uploade files' );
        my $site_root = $plugin->translate( 'Site Root' );
        my $up2 = $plugin->translate( 'Upload Destination' );
        $static_path .= 'plugins';
        my $header =<<MTML;
        <link rel="stylesheet" href="$static_path/MultiUploader/jquery-ui.css" id="theme" />
        <link rel="stylesheet" href="$static_path/MultiUploader/jquery.fileupload-ui.css" />
MTML
        $$tmpl =~ s!(</head>)!$header$1!;
        my $pointer = quotemeta( '<form method="post" enctype="multipart/form-data"' );
        my $form =<<MTML;
<form id="file_upload" action="$action" method="POST" enctype="multipart/form-data">
    <input type="hidden" name="__mode" value="upload_multi" />
    <input type="hidden" name="blog_id" value="$blog_id" />
    <input type="hidden" name="middle_path" id="middle_path" value="$upload_path" />
    <input type="hidden" name="magic_token" value="$current_magic" />
    <input type="file" name="file" multiple="multiple" />
    <button>Upload</button>
    <div>$label</div>
</form>
<table id="files" align="left" style="margin-top:1em"></table>
<br style="clear:both;" />
<div id="site_path-field" class="field field-top-label ">
    <div class="field-header">
      <label id="upload_path-label" for="upload_path">$up2</label>
    </div>
    <div class="field-content ">
        <p style="margin-top:1em">&#60;$site_root&#62; /
    <input type="text"  value="$upload_path" id="upload_path" name="upload_path" style="width:160px;" onkeyup="setMiddlePath(this)" onchange="setMiddlePath(this)" /></p>
    </div>
</div>
<script type="text/javascript">
function setMiddlePath ( fld ) {
   var path = fld.value;
   if (!path) path = '';
   var middle = getByID( 'middle_path' );
   if ( middle ) middle.value = path;
}
</script>

<script src="$static_path/MultiUploader/jquery-ui.min.js"></script>
<script src="$static_path/MultiUploader/jquery.fileupload.js"></script>
<script src="$static_path/MultiUploader/jquery.fileupload-ui.js"></script>
MTML
        my $script =<<'MTML';
<script type="text/javascript">
/*global $ */
jQuery(function () {
    jQuery('#file_upload').fileUploadUI({
        uploadTable: jQuery('#files'),
        downloadTable: jQuery('#files'),
        buildUploadRow: function (files, index) {
            return jQuery('<tr><td>' + files[index].name + '<\/td>' +
                    '<td class="file_upload_progress"><div><\/div><\/td>' +
                    //'<td class="file_upload_cancel">' +
                    //'<button class="ui-state-default ui-corner-all" title="Cancel">' +
                    //'<span class="ui-icon ui-icon-cancel">Cancel<\/span>' +
                    //'<\/button><\/td><\/tr>');
                    '<\/td><\/tr>');
        },
        buildDownloadRow: function (file) {
            return jQuery('<tr><td>' + file.name + '<\/td><\/tr>');
        }
    });
});
</script>
MTML
        $$tmpl =~ s!$pointer.*?</form>!$form$script!si;
    }
}

1;