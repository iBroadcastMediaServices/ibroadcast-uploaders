#!/usr/bin/env python

import json
import glob
import os
import hashlib
import sys
import traceback
import time
import io

import requests
import segno

sys.tracebacklimit = 0

def get_input(inp):
    if sys.version_info >= (3, 0):
        return input(inp)
    else:
        return raw_input(inp)

class OAuthError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

    def __reduce__(self):
        return (OAuthError, (self.code, self.message))

class ServerError(Exception):
    pass

class ValueError(Exception):
    pass

class Uploader(object):
    """
    Class for uploading content to iBroadcast.
    """

    VERSION = '0.4'
    CLIENT = 'python 3 uploader script'
    DEVICE_NAME = 'python 3 uploader script'
    USER_AGENT = 'python 3 uploader script 0.4'
    CLIENT_ID = 'de4ce836a9fb11f0bc7fb49691aa2236'


    def __init__(self):

        # Initialize our variables that each function will set.
        self.token = None
        self.user = None

        self.supported = None
        self.files = None
        self.md5 = None

    def loadToken(self):
        self.token = None
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ibroadcast-uploader.json')) as f:
                j = json.load(f)
                self.token = j['token']
        except:
            pass

    def saveToken(self):
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ibroadcast-uploader.json'), 'w') as f:
                json.dump({ 'token': self.token }, f)
        except Exception as e:
            print(f'Warning, unable to save token to ibroadcast-uploader.json: {str(e)}')


    def login(self):
        device_code = None

        # Need to refresh token?
        self.refreshTokenIfNecessary()

        # Loop until we have a token
        while self.token is None:
            # Get device code if we don't have one yet
            if device_code is None:
                try:
                    device_code = self.oauthDeviceCode()
                    device_code['expires_at'] = time.time() + device_code['expires_in']

                    # Generate and show barcode and URL
                    qrcode = segno.make(device_code['verification_uri_complete'], error='h')
                    buffer = io.StringIO()
                    qrcode.terminal(out=buffer)
                    print(buffer.getvalue())

                    # Visit URL
                    print(f'To authorize, scan the QR code or enter code {device_code['user_code']} at: {device_code['verification_uri']}')

                    print('\nWaiting for authorization...')
                except Exception as e:
                    print(f'Unable to get device code: {str(e)}')
                    return False
            
            # Check device code expiry
            if device_code['expires_at'] <= time.time():
                print('Device code timed out!')
                # Remove it and start over
                device_code = None
                continue
            
            
            # Poll for token
            try:
                self.token = self.oauthToken(device_code['device_code'])
                self.token['expires_at'] = time.time() + self.token['expires_in']
            except OAuthError as e:
                if e.code == 'authorization_pending':
                    time.sleep(device_code['interval'])
                    continue
                    
                print(f'Authorization error: {str(e)}')
                return False
            
            # Authorization successful! Stop looping
            break

        return True

    def process(self):
        # Get supported types and account info
        try:
            self.get_supported_types()
        except ValueError as e:
            print('Unable to fetch account info: %s' % e)
            return

        self.load_files()

        if self.confirm():
            self.upload()

    def oauthDeviceCode(self):
        """
        Gets a device code

        Raises:
            OAuthError

        """
        print('Getting device code...')
        
        query_params = {
            'client_id' : self.CLIENT_ID,
            'scope' : ' '.join(['user.account:read', 'user.upload'])
        }
        response = requests.get(
            'https://oauth.ibroadcast.com/device/code',
            params=query_params,
            headers={'User-Agent': self.USER_AGENT}
        )

        response_json = response.json()

        if not response.ok:
            raise OAuthError(response_json['error'], response_json['error_description'])

        return response_json

    def oauthToken(self, code):
        """
        Gets a token given a device code

        Raises:
            OAuthError

        """
        # print('Getting token...')
        
        body = {
            'client_id' : self.CLIENT_ID,
            'grant_type' : 'device_code',
            'device_code' : code
        }
        response = requests.post(
            'https://oauth.ibroadcast.com/token',
            data=body,
            headers={'User-Agent': self.USER_AGENT}
        )

        response_json = response.json()

        if not response.ok:
            raise OAuthError(response_json['error'], response_json['error_description'])

        return response_json

    def refreshToken(self, refresh_token):
        """
        Refreshes a token

        Raises:
            OAuthError

        """
        print('Refreshing token...')
        
        body = {
            'client_id' : self.CLIENT_ID,
            'grant_type' : 'refresh_token',
            'refresh_token' : refresh_token
        }
        response = requests.post(
            'https://oauth.ibroadcast.com/token',
            data=body,
            headers={'User-Agent': self.USER_AGENT}
        )

        response_json = response.json()

        if not response.ok:
            raise OAuthError(response_json['error'], response_json['error_description'])

        return response_json

    def refreshTokenIfNecessary(self):
        if self.token is None:
            return
        
        if self.token['expires_at'] <= time.time():
            try:
                self.token = self.refreshToken(self.token['refresh_token'])
                self.token['expires_at'] = time.time() + self.token['expires_in']
            except OAuthError as e:
                print(f'Authorization error, please log in again: {str(e)}')
                self.token = None

    def get_supported_types(self):
        """
        Get supported file types

        Raises:
            ValueError on invalid login

        """
        print('Fetching account info...')
        # Build a request object.
        post_data = json.dumps({
            'mode' : 'status',
            'supported_types': 1,
            'version': self.VERSION,
            'client': self.CLIENT,
            'device_name' : self.DEVICE_NAME,
            'user_agent' : self.USER_AGENT
        })
        response = requests.post(
            "https://api.ibroadcast.com/s/JSON/",
            data=post_data,
            headers={'Content-Type': 'application/json', 'User-Agent': self.USER_AGENT, 'Authorization': f'{self.token['token_type']} {self.token['access_token']}'}
        )

        if not response.ok:
            raise ServerError('Server returned bad status: ',
                             response.status_code)

        jsoned = response.json()

        if 'user' not in jsoned:
            raise ValueError(jsoned.message)

        print('Account info fetched')

        self.supported = []
        self.files = []

        for filetype in jsoned['supported']:
             self.supported.append(filetype['extension'])

    def load_files(self, directory=None):
        """
        Load all files in the directory that match the supported extension list.

        directory defaults to present working directory.

        raises:
            ValueError if supported is not yet set.
        """
        if self.supported is None:
            raise ValueError('Supported not yet set - have you logged in yet?')

        if not directory:
            directory = os.getcwd()

        for full_filename in glob.glob(os.path.join(directory, '*')):
            filename = os.path.basename(full_filename)
            # Skip hidden files.
            if filename.startswith('.'):
                continue

            # Make sure it's a supported extension.
            dummy, ext = os.path.splitext(full_filename)
            if ext in self.supported:
                self.files.append(full_filename)

            # Recurse into subdirectories.
            # XXX Symlinks may cause... issues.
            if os.path.isdir(full_filename):
                self.load_files(full_filename)

    def confirm(self):
        """
        Presents a dialog for the user to either list all files, or just upload.
        """
        print("Found %s files.  Press 'L' to list, or 'U' to start the " \
              "upload." % len(self.files))
        response = get_input('--> ')

        print()
        if response == 'L'.upper():
            print('Listing found, supported files')
            for filename in self.files:
                print(' - ', filename)
            print()
            print("Press 'U' to start the upload if this looks reasonable.")
            response = get_input('--> ')
        if response == 'U'.upper():
            print('Starting upload.')
            return True

        print('Aborting')
        return False

    def __load_md5(self):
        """
        Reach out to iBroadcast and get an md5.
        """
        # Send our request.
        response = requests.post(
            "https://upload.ibroadcast.com",
            headers={'Authorization': f'{self.token['token_type']} {self.token['access_token']}'}
        )

        if not response.ok:
            raise ServerError('Server returned bad status: ',
                             response.status_code)

        jsoned = response.json()

        self.md5 = jsoned['md5']

    def calcmd5(self, filePath="."):
        with open(filePath, 'rb') as fh:
            m = hashlib.md5()
            while True:
                data = fh.read(8192)
                if not data:
                    break
                m.update(data)
        return m.hexdigest()

    def upload(self):
        """
        Go and perform an upload of any files that haven't yet been uploaded
        """
        self.__load_md5()

        for filename in self.files:

            print('Uploading ', filename)

            # Get an md5 of the file contents and compare it to whats up
            # there already
            file_md5 = self.calcmd5(filename)

            if file_md5 in self.md5:
                print('Skipping - already uploaded.')
                continue
            upload_file = open(filename, 'rb')

            file_data = {
                'file': upload_file,
            }

            post_data = {
                'file_path' : filename,
                'method': self.CLIENT,
            }

            response = requests.post(
                "https://upload.ibroadcast.com",
                post_data,
                files=file_data,
                headers={'Authorization': f'{self.token['token_type']} {self.token['access_token']}'}
            )

            ## refresh and retry one time
            if response.status_code == 401:
                self.refreshTokenIfNecessary()
                response = requests.post(
                    "https://upload.ibroadcast.com",
                    post_data,
                    files=file_data,
                    headers={'Authorization': f'{self.token['token_type']} {self.token['access_token']}'}
                )

            upload_file.close()

            if not response.ok:
                raise ServerError('Server returned bad status: ',
                    response.status_code)
            jsoned = response.json()
            result = jsoned['result']

            if result is False:
                raise ValueError('File upload failed.')
        print('Done')

if __name__ == '__main__':
    uploader = Uploader()

    # Load token from local storate if possible
    uploader.loadToken()

    # Login or refresh token if necessary
    if uploader.login():
        # Save token to local storage
        uploader.saveToken()

        # Ready to start processing files
        uploader.process()
