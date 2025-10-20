<?php
require 'vendor/autoload.php';

use chillerlan\QRCode\{QRCode, QROptions};
use chillerlan\QRCode\Output\QROutputInterface;
use chillerlan\QRCode\Output\QRString;
use chillerlan\QRCode\Data\QRMatrix;

const CLIENT_ID = 'de4ce836a9fb11f0bc7fb49691aa2236';
const USER_AGENT = 'php uploader 1.0';

ini_set('memory_limit' , '1024M');

class OAuthError extends Exception {
    public $error_code;

    public function __construct(string $errorCode, string $message, int $code = 0, ?Throwable $previous = null) {
        $this->error_code = $errorCode;
        parent::__construct($message, $code, $previous);
    }

    public function __toString(): string {
        return "Authorization error [{$this->error_code}]: {$this->getMessage()}";
    }
}

class HTTPError extends Exception {
    public $status_code;

    public function __construct(string $statusCode, string $message, int $code = 0, ?Throwable $previous = null) {
        $this->status_code = $statusCode;
        parent::__construct($message, $code, $previous);
    }

    public function __toString(): string {
        return "HTTP error [{$this->error_code}]: {$this->getMessage()}";
    }
}

$token = loadToken();

$token = login($token);

if ($token === null) {
	fwrite(STDOUT, 'Unable to log in.' . "\n");
	exit(0);
}

saveToken($token);

// Fetch supported types
fwrite(STDOUT, 'Fetching account info...' . "\n");

$serviceContent  = getSupportedTypes($token);

if ($serviceContent == null || !isset($serviceContent->user)) {
	fwrite(STDOUT, ($serviceContent ? $serviceContent->message : 'Unable to get supported types.') . "\n");
	exit(0);
}

// Extract supported file formats from the service response
$supportedFormat = getSupportedFormats($serviceContent);

fwrite(STDOUT, 'Searching for files...' . "\n");

// Fetch the file list from the service
$syncContent     = getSyncContent($token);
$alreadyUploaded = isset($syncContent->md5) && is_array($syncContent->md5) ? $syncContent->md5 : array();

$files = array();

// Bootstrap the script, recursive method in order to traverse sub-folders
readFiles(getcwd(), $files);

// Display a nice welcome text with instructions
fwrite(STDOUT, sprintf("Found %s file(s). Press \"L\" to list or \"U\" to start the upload. [Q to Quit]\n", count($files)));
do {
	do {
		// Wait for user input
		$cmd = strtoupper(fgetc(STDIN));

	} while (trim($cmd) == '');

	if ($cmd == 'L') {

		// Display a list of files that were found in the dir and all child-dirs
		cmdList($files);
	} else if ($cmd == 'U') {

		// Trigger the upload action
		cmdUpload($files, $alreadyUploaded, $token);
		exit(0);
	}

// Allow user to abort using "Q"
} while ($cmd !== 'Q');


function getDefaultPostData($mode) {
	return array(
		'mode' => $mode,
		'client' => 'php uploader',
		'version' => '1.0',
		'device_name' => 'php uploader',
		'user_agent' => USER_AGENT
	);
}

function cmdList($files) {
	fwrite(STDOUT, "Listing found, supported files\n");

	// Display all files that are available for uploading
	foreach ($files as $file) {
		fwrite(STDOUT, $file . "\n");
	}

	fwrite(STDOUT, "Press 'U' to start the upload if this looks reasonable\n");
}

function cmdUpload($files, $alreadyUploaded, $token) {
	fwrite(STDOUT, "Uploading..\n");

	foreach ($files as $file) {
		fwrite(STDOUT, "Uploading: $file\n");

		$checksum = md5_file($file);

		// Check if the file already exists on the service, if yes, then skipp
		if (in_array($checksum, $alreadyUploaded)) {
			fwrite(STDOUT, "  skipping, already uploaded.\n");
			continue;
		}

		// File is allowed to be uploaded
		$success = false;
		try {
			$success = uploadFile($file, $token);
		} catch (HTTPError $e) {
			if ($e.status_code == "401") {
				$token = refreshTokenIfNecessary();
				$success = uploadFile($file, $token);
			}
		}

		if ($success) {
			fwrite(STDOUT, " Done!\n");
		} else {
			fwrite(STDOUT, "Failed!\n");
		}
	}
}

/**
 * Loads the token from the JSON file.
 */
function loadToken() {
	$path = __DIR__ . '/ibroadcast-uploader.json';

	if (!file_exists($path)) {
		return null;
	}

	try {
		$jsonContents = file_get_contents($path);

		$data = json_decode($jsonContents, true, 512, JSON_THROW_ON_ERROR);

		if (isset($data['token'])) {
			return $data['token'];
		}
	} catch (Throwable $e) {
		// Silently fail if file is unreadable or corrupt, as in the Python original.
	}

	return null;
}

/**
 * Saves the current token to the JSON file.
 */
function saveToken($token) {
	$path = __DIR__ . '/ibroadcast-uploader.json';

	try {
		$data = ['token' => $token];
		file_put_contents($path, json_encode($data, JSON_THROW_ON_ERROR));
		return true;
	} catch (Throwable $e) {
		fwrite(STDOUT, 'Warning, unable to save token to ibroadcast-uploader.json: ' . $e->getMessage() . PHP_EOL);
		return false;
	}
}

/**
 * The main login flow using the OAuth Device Code grant.
 * @return bool True on success, false on failure.
 */
function login($token) {
	$deviceCode = null;

	// Attempt to refresh the token if it's expired
	$token = refreshTokenIfNecessary($token);

	// Loop until we have a valid token
	while ($token === null) {
		// Get a new device code if we don't have one
		if ($deviceCode === null) {
			try {
				$deviceCode = oauthDeviceCode();
				$deviceCode['expires_at'] = time() + $deviceCode['expires_in'];

				// Generate and show QR code for the terminal
				$options = new QROptions(['outputType' => QROutputInterface::STRING_TEXT]);
				$qrcode = (new QRCode($options))->render($deviceCode['verification_uri_complete']);
				fwrite(STDOUT, $qrcode . PHP_EOL);

				fwrite(STDOUT, "To authorize, scan the QR code or enter code {$deviceCode['user_code']} at: {$deviceCode['verification_uri']}" . PHP_EOL);
				fwrite(STDOUT, PHP_EOL . 'Waiting for authorization...' . PHP_EOL);
			} catch (Throwable $e) {
				fwrite(STDOUT, 'Unable to get device code: ' . $e->getMessage() . PHP_EOL);
				return null;
			}
		}

		// Check if the device code has expired
		if ($deviceCode['expires_at'] <= time()) {
			fwrite(STDOUT, 'Device code timed out!' . PHP_EOL);
			$deviceCode = null; // Remove it to start over
			continue;
		}

		// Poll for the authorization token
		try {
			$token = oauthToken($deviceCode['device_code']);
			$token['expires_at'] = time() + $token['expires_in'];
		} catch (OAuthError $e) {
			if ($e->error_code === 'authorization_pending') {
				sleep($deviceCode['interval']); // Wait and poll again
				continue;
			}
			fwrite(STDOUT, 'Authorization error: ' . $e->getMessage() . PHP_EOL);
			return null;
		}

		// Authorization successful! Save the token and break the loop.
		saveToken($token);
		break;
	}

	return $token;
}

/**
 * Checks if the token is expired and refreshes it if necessary.
 */
function refreshTokenIfNecessary($token) {
	if ($token === null || !isset($token['expires_at'])) {
		return null;
	}

	if ($token['expires_at'] <= time()) {
		try {
			$token = refreshToken($token['refresh_token']);
			$token['expires_at'] = time() + $token['expires_in'];
			saveToken(); // Save the newly refreshed token
		} catch (OAuthError $e) {
			fwrite(STDOUT, 'Authorization error, please log in again: ' . $e->getMessage() . PHP_EOL);
			$token = null; // Invalidate the token
			saveToken(); // Save the invalidated state
		}
	}

	return $token;
}

/**
 * Gets a device code from the OAuth server.
 * @throws OAuthError
 * @return array
 */
function oauthDeviceCode() {
	fwrite(STDOUT, 'Getting device code...' . PHP_EOL);

	$queryParams = http_build_query([
		'client_id' => CLIENT_ID,
		'scope' => 'user.account:read user.upload'
	]);
	$url = 'https://oauth.ibroadcast.com/device/code?' . $queryParams;

	return makeRequest($url, 'GET');
}

/**
 * Gets an access token given a device code.
 * @param string $code The device code.
 * @throws OAuthError
 * @return array
 */
function oauthToken($code) {
	$body = [
		'client_id' => CLIENT_ID,
		'grant_type' => 'device_code',
		'device_code' => $code
	];

	return makeRequest('https://oauth.ibroadcast.com/token', 'POST', $body);
}

/**
 * Refreshes an access token using a refresh token.
 * @param string $refreshToken
 * @throws OAuthError
 * @return array
 */
function refreshToken($refreshToken) {
	fwrite(STDOUT, 'Refreshing token...' . PHP_EOL);
	$body = [
		'client_id' => CLIENT_ID,
		'grant_type' => 'refresh_token',
		'refresh_token' => $refreshToken
	];

	return makeRequest('https://oauth.ibroadcast.com/token', 'POST', $body);
}

/**
 * A helper function to make cURL requests.
 *
 * @param string $url The URL to request.
 * @param string $method The HTTP method (GET or POST).
 * @param array|null $postData Data for POST requests.
 * @return array The JSON-decoded response.
 * @throws OAuthError|JsonException
 */
function makeRequest($url, $method = 'GET', $postData = null) {
	$ch = curl_init();

	curl_setopt($ch, CURLOPT_URL, $url);
	curl_setopt($ch, CURLOPT_USERAGENT, USER_AGENT);
	curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);

	if ($method === 'POST') {
		curl_setopt($ch, CURLOPT_POST, true);
		curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($postData));
	}

	$response = curl_exec($ch);
	$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
	curl_close($ch);

	$responseJson = json_decode($response, true, 512, JSON_THROW_ON_ERROR);

	if ($httpCode < 200 || $httpCode >= 300) {
		throw new OAuthError($responseJson['error'] ?? 'unknown_error', $responseJson['error_description'] ?? 'An unknown error occurred.');
	}

	return $responseJson;
}


/**
 * Returns supported types
 *
 * @param string $login_token
 *
 * @return stdClass
 */
function getSupportedTypes($token) {
	$postData = getDefaultPostData('status');

	$postData['supported_types'] = 1;

	$encodedData = json_encode($postData);

	$result = file_get_contents(
		'https://api.ibroadcast.com/s/JSON/',
		false,
		stream_context_create(
			array(
				'http' => array(
					'method' => 'POST',
					'header' => 'Content-Type: application/json' . "\r\n"
						. 'Content-Length: ' . strlen($encodedData) . "\r\n"
						. 'User-Agent: ' . $postData['user_agent'] . "\r\n"
						. 'Authorization: ' . $token['token_type'] . ' ' . $token['access_token'] . "\r\n",
					'content' => $encodedData,
				),
			)
		)
	);

	return json_decode($result);
}

/**
 * Returns a hash map of uploaded files.
 *
 * @param array $token
 *
 * @return stdClass
 */
function getSyncContent($token)
{
	$postData = http_build_query(
		array(
		)
	);

	$result = file_get_contents(
		'https://upload.ibroadcast.com',
		false,
		stream_context_create(
			array(
				'http' => array(
					'method' => 'POST',
					'header' => 'Content-Type: application/x-www-form-urlencoded' . "\r\n"
						. 'Content-Length: ' . strlen($postData) . "\r\n"
						. 'User-Agent: ' . 'php uploader 1.0' . "\r\n"
						. 'Authorization: ' . $token['token_type'] . ' ' . $token['access_token'] . "\r\n",
					'content' => $postData,
				)
			)
		)
	);

	return json_decode($result);
}

/**
 * Uploads the given file to the remote service.
 *
 * @param string $file
 * @param array $token
 *
 * @return bool True, if the file upload was successful
 */
function uploadFile($file, $token) {
	$multipartBoundary = '-----------'.microtime(true);
	$header = 'Content-Type: multipart/form-data; boundary=' . $multipartBoundary . "\r\n"
			. 'User-Agent: ' . 'php uploader 1.0' . "\r\n"
			. 'Authorization: ' . $token['token_type'] . ' ' . $token['access_token'] . "\r\n";

	$file_contents = file_get_contents($file);
	$contentType   = mime_content_type($file);

	$content .= "--".$multipartBoundary."\r\n".
		"Content-Disposition: form-data; name=\"file_path\"\r\n\r\n".
		"$file\r\n";

	$content .= "--".$multipartBoundary."\r\n".
		"Content-Disposition: form-data; name=\"method\"\r\n\r\n".
		"php uploader\r\n";

	$content .=  "--".$multipartBoundary."\r\n".
		"Content-Disposition: form-data; name=\"file\"; filename=\"".basename($file)."\"\r\n".
		"Content-Type: $contentType\r\n\r\n".
		$file_contents."\r\n";

	$content .= "--".$multipartBoundary."--\r\n";

	file_get_contents(
		'https://upload.ibroadcast.com',
		false,
		stream_context_create(
			array(
				'http' => array(
					'method' => 'POST',
					'header' => $header,
					'content' => $content,
				)
			)
		)
	);

	preg_match('{HTTP\/\S*\s(\d{3})}', $http_response_header[0], $match);
	$status = $match[1];

	if ($status == "401") {
		
	}

	return true;
}

/**
 * Returns an array of allowed file extensions.
 *
 * @param stdClass $serviceContent
 *
 * @return array
 */
function getSupportedFormats($serviceContent) {
	$supportedFormat = array();
	foreach ($serviceContent->supported as $key => $format) {
		$supportedFormat[] = str_replace('.', '', $format->extension);
	}
	return $supportedFormat;
}

/**
 * Recursive function for traversing directories.
 *
 * @param string $dirPath
 * @param array $files
 */
function readFiles($dirPath, &$files) {
	global $supportedFormat, $files;

	$dirContent = scandir($dirPath);

	foreach ($dirContent as $key => $item) {
		// Skipp hidden files and parent folder references
		if (in_array($item, array('.','..')) || $item[0] === '.') {
			continue;
		}

		$itemPath = $dirPath . '/' . $item;

		if (is_dir($itemPath)) {
			readFiles($itemPath, $files);
		} else if (is_file($itemPath)) {
			$fileInfo = explode('.', $item);

			if (count($fileInfo) > 1 && in_array(end($fileInfo), $supportedFormat)) {
				$files[] = $itemPath;
			}
		}
	}
}

exit(0);
