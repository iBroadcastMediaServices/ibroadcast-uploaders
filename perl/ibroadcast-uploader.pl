#!/usr/bin/perl
##############################################################################################################################################

use strict;
use warnings;

use Cwd qw(getcwd);
use Digest::MD5;
use JSON::XS;
use LWP::UserAgent;
use HTTP::Request::Common;
use Time::HiRes qw(sleep);

use constant CLIENT_ID => "de4ce836a9fb11f0bc7fb49691aa2236";
use constant USER_AGENT => "perl uploader 0.3";
use constant UPLOAD_METHOD => "perl uploader";



$| = 1; ######################################################################################################################################


sub get_req {
    my $mode = shift;

    my $req = {
        mode => $mode,
        version => "0.2",
        client => UPLOAD_METHOD,
        user_agent => USER_AGENT
    };

    return $req;
}


sub _confirm  {

    my $res = shift;

    print "Found " . ($#{$res} + 1) . " files. Press 'L' to list, or 'U' to start the upload.\n";

    my $confirm = <STDIN>;

    if ($confirm =~ /L/i) {

        print "\nListing found, supported files\n";

        foreach (@{ $res }) { print " - $_\n"; }

        print "Press 'U' to start the upload if this looks reasonable.\n";

        $confirm = <STDIN>;

        if ($confirm =~ /U/i) {

            print "Starting upload\n";

            return 1;

        } else {

            print "aborted.\n";

            return 0;
        }


    } elsif ($confirm =~ /U/i) {

        print "Starting upload\n";

        return 1;

    } else {

        print "aborted.\n";

        return 0;
    }
}


sub _get_md5 {

    my $token = shift;
    my $ua = LWP::UserAgent->new;

    my $req = HTTP::Request->new(POST => "https://upload.ibroadcast.com");

    $req->content_type("application/x-www-form-urlencoded");

    $req->header("User-Agent" => USER_AGENT);
    $req->header("Authorization" => "$token->{token_type} $token->{access_token}");

    my $resp = $ua->request($req);

    my $j = JSON::XS->new->utf8->decode($resp->content);

    return $j->{md5};
}


sub _upload_files {

    my $files = shift;
    my $token = shift;

    my $md5 = _get_md5($token);

    foreach my $f (@{ $files }) {

        open(my $fh, $f) or print "Unable read $f $!\n" and return;
        binmode $fh;

        ## Create MD5
        my $ctx = Digest::MD5->new;
           $ctx->addfile($fh);

        close ($fh);

        my $digest = $ctx->hexdigest;

        my $ok = 1;

        print "Uploading: $f\n";

        ## check against uploaded md5 list
        foreach my $m (@{ $md5 }) {

            next if !$m;

            ## already uploaded
            if ($m eq $digest) {

                $ok = 0;
                print " skipping, already uploaded\n";
                last;
            }
        }

        next if !$ok;


        my $ua = LWP::UserAgent->new;

        my $req = POST 'https://upload.ibroadcast.com',
            Content_Type => 'form-data',
            Content => [
                file => [ $f ],
                file_path => $f,
				method => UPLOAD_METHOD
            ];

        $req->header("User-Agent" => USER_AGENT);
        $req->header("Authorization" => "$token->{token_type} $token->{access_token}");

        my $resp = $ua->request($req);

        ## reauth and try one more time
        if ($resp->code == 401) {
            $token = refresh_token_if_necessary($token);

            $req = POST 'https://upload.ibroadcast.com',
            Content_Type => 'form-data',
            Content => [
                file => [ $f ],
                file_path => $f,
				method => UPLOAD_METHOD
            ];

            $req->header("User-Agent" => USER_AGENT);
            $req->header("Authorization" => "$token->{token_type} $token->{access_token}");

            $resp = $ua->request($req);
        }

        if ($resp->is_success) {

            print " Done!\n";
        }

        else {

            print " Failed.\n";
        }
    }
}


sub _list_files {

    my $dir = shift;
    my $supported = shift;
    
    my $files = [];

    opendir(my $dh, $dir) || return $files;

    while (my $fn = readdir($dh)) {

        ## skip hidden
        next if $fn =~ /^\./; 

        ## file, fullpath name
        my $file = $dir . "/" . $fn;

        ## extension
        my ($ext) = $file =~ m/(\..{2,5})/;

        ## add
        push(@{ $files }, $file) if $ext && $supported->{$ext};

        ## dir, decend
        if (-d $file) {

            ## sub-directory files
            $files = _list_files($file, $files);
        }
    }

    closedir($dh);

    return $files;
}

# Loads token from JSON file
sub load_token {
    my $path = File::Spec->catfile(__DIR__(), 'ibroadcast-uploader.json');

    return undef unless -e $path;

    my $token;
    open my $fh, '<', $path or return undef;
    local $/;
    my $json = <$fh>;
    close $fh;

    my $data = decode_json($json);
    $token = $data->{token} if exists $data->{token};

    return $token;
}

# Saves token to JSON file
sub save_token {
    my $token = shift;
    my $path = File::Spec->catfile(__DIR__(), 'ibroadcast-uploader.json');

    my $data = { token => $token };
    open my $fh, '>', $path or return undef;
    print $fh encode_json($data);
    close $fh;
    return 1;
}

# Gets device code from OAuth server
sub oauth_device_code {
    print "Getting device code...\n";

    my $ua = LWP::UserAgent->new;
    my $url = 'https://oauth.ibroadcast.com/device/code?' . 
        'client_id=' . CLIENT_ID . '&scope=user.account:read%20user.upload';

    my $response = $ua->request(GET $url);

    if ($response->is_success) {
        return decode_json($response->decoded_content);
    } else {
        return undef;
    }
}

# Gets access token using device code
sub oauth_token {
    my $code = shift;

    my $ua = LWP::UserAgent->new;
    my $response = $ua->post('https://oauth.ibroadcast.com/token', {
        client_id   => CLIENT_ID,
        grant_type  => 'device_code',
        device_code => $code,
    });

    if ($response->is_success) {
        return decode_json($response->decoded_content);
    } else {
        my $err = decode_json($response->decoded_content);
        if ($err->{error} eq "authorization_pending") {
            return { pending => 1 };
        } else {
            return undef;
        }
    }
}

# Refreshes the access token
sub refresh_token {
    my $refresh_token = shift;
    print "Refreshing token...\n";

    my $ua = LWP::UserAgent->new;
    my $response = $ua->post('https://oauth.ibroadcast.com/token', {
        client_id     => CLIENT_ID,
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
    });

    if ($response->is_success) {
        return decode_json($response->decoded_content);
    } else {
        return undef;
    }
}

# Refresh token if expired
sub refresh_token_if_necessary {
    my $token = shift;

    return undef unless $token && $token->{expires_at};

    if ($token->{expires_at} <= time) {
        $token = refresh_token($token->{refresh_token});

        if ($token) {
            $token->{expires_at} = time + $token->{expires_in};
        } else {
            print "Authorization error, please log in again\n";
            $token = undef;
        }
        save_token($token);
    }

    return $token;
}

# Main login function
sub login {
    my $token = shift;
    my $device_code;

    $token = refresh_token_if_necessary($token);

    while (!$token) {
        if (!$device_code) {
            $device_code = oauth_device_code();

            if (!$device_code) {
                print "Unable to get device code: $_\n";
                return undef;
            }

            $device_code->{expires_at} = time + $device_code->{expires_in};

            # Simulate QR code / output
            print "\nTo authorize, visit: $device_code->{verification_uri_complete}\n";
            print "Or enter code $device_code->{user_code} at $device_code->{verification_uri}\n";
            print "Waiting for authorization...\n\n";
        }

        if ($device_code->{expires_at} <= time) {
            print "Device code timed out!\n";
            $device_code = undef;
            next;
        }

        $token = oauth_token($device_code->{device_code});

        if (!$token) {
            print "Authorization error\n";
            return undef;
        }

        if ($token->{pending}) {
            $token = undef;
            sleep($device_code->{interval});
            next;
        }

        $token->{expires_at} = time + $token->{expires_in};

        save_token($token);
        last;
    }

    return $token;
}

# -------------------------
# Helper to get script dir
sub __DIR__ {
    use Cwd 'abs_path';
    use File::Basename;
    return dirname(abs_path($0));
}


##############################################################################################################################################

my $token = load_token();

$token = login($token);

if (!$token) {
    print "Unable to log in\n";
    exit;
}

save_token($token);


## Get supported types
my $req = get_req("status");

$req->{supported_types} = 1;


## Convert request to json
my $json_out = JSON::XS->new->utf8->encode($req);


## Post it to api.ibroadcast.com
my $ua = LWP::UserAgent->new;
my $response = $ua->post("https://api.ibroadcast.com/s/JSON/" . $req->{mode}, Content => $json_out, "User-Agent" => USER_AGENT, "Authorization" => "$token->{token_type} $token->{access_token}");


## Parse the response
my $j = JSON::XS->new->utf8->decode($response->content);

if (!$j->{user}->{id}) {

    print "Could not get list of supported file types\n";
    exit;
}



## convert the supported array ref to a hashref
my $supported;

foreach (@{ $j->{supported} }) {

    $supported->{ $_->{extension} } = 1;
}


## current working directory
my $cwd = getcwd;


## Get files from cwd 
my $res = _list_files($cwd, $supported);


## confirm upload with user
my $ok = _confirm($res);


## upload
_upload_files($res, $token) if $ok;


exit;

##############################################################################################################################################