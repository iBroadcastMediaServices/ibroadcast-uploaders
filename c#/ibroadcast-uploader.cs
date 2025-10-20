using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.IO;
using System.Data;
using System.Diagnostics;

using RestSharp;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Reflection.Metadata.Ecma335;
using System.Text.Json.Serialization;

namespace ibroadcast_uploader
{
    public class OAuthException : Exception
    {
        public string Code { get; }

        public OAuthException(string code, string message) : base(message)
        {
            Code = code;
        }
    }

    public class OAuthError
    {
        [JsonPropertyName("error")]
        public required string Error { get; set; }
        [JsonPropertyName("error_description")]
        public required string ErrorDescription { get; set; }
    }

    public class OAuthToken
    {
        [JsonPropertyName("access_token")]
        public required string AccessToken { get; set; }
        [JsonPropertyName("token_type")]
        public required string TokenType { get; set; }
        [JsonPropertyName("refresh_token")]
        public required string RefreshToken { get; set; }
        [JsonPropertyName("expires_in")]
        public required int ExpiresIn { get; set; }
        [JsonPropertyName("expires_at")]
        public long? ExpiresAt { get; set; }
    }

    public class OAuthDeviceCode
    {
        [JsonPropertyName("device_code")]
        public required string DeviceCode { get; set; }
        [JsonPropertyName("user_code")]
        public required string UserCode { get; set; }
        [JsonPropertyName("verification_uri")]
        public required string VerificationUri { get; set; }
        [JsonPropertyName("verification_uri_complete")]
        public required string VerificationUriComplete { get; set; }
        [JsonPropertyName("interval")]
        public required int Interval { get; set; }
        [JsonPropertyName("expires_in")]
        public required int ExpiresIn { get; set; }
        [JsonPropertyName("expires_at")]
        public long? ExpiresAt { get; set; }
    }


    public class ibroadcast_uploader
    {
        private static readonly String SYNC_ENDPOINT = "https://upload-dev.ibroadcast.com";
	    private static readonly String API_ENDPOINT = "https://api-dev.ibroadcast.com/";
        private static readonly String CLIENT_ID = "de4ce836a9fb11f0bc7fb49691aa2236";
	    private static readonly String USER_AGENT = "C# upload client 1.2";
	    private static readonly String JSON_CONTENT_TYPE = "application/json";
        private static readonly String URL_CONTENT_TYPE = "application/x-www-form-urlencoded";

        private static readonly String CLIENT = "C# upload client";
	    private static readonly String VERSION = "1.2";

        private static readonly String TOKEN_FILE = "ibroadcast-uploader.json";

        private List<String> extensions = new List<String>();
        private List<String> md5s = new List<String>();
        private List<FileInfo> mediaFilesQ = new List<FileInfo>();

        public static void Main(string[] args)
        {
            ibroadcast_uploader uploader = new ibroadcast_uploader(args);

            var token = uploader.LoadToken();
            token = uploader.Login(token);

            if (token == null) {
                Console.WriteLine("Unable to log in", Process.GetCurrentProcess().ProcessName);
                Environment.Exit(-1);
            }

            uploader.SaveToken(token);
            
            uploader.status(token);
            uploader.getMD5(token);
            uploader.mediaFilesQ = uploader.loadMediaFilesQ(Environment.CurrentDirectory);
            uploader.executeOptions(token);
        }

        public ibroadcast_uploader(string[] args)
        {
        }

        public OAuthToken? LoadToken()
        {
            var path = Path.Combine(Directory.GetCurrentDirectory()!, TOKEN_FILE);

            try
            {
                if (File.Exists(TOKEN_FILE))
                {
                    string json = File.ReadAllText(path);
                    return JsonSerializer.Deserialize<OAuthToken>(json);
                }
            }
            catch
            {
                // Do nothing
            }

            return null;
        }

        public void SaveToken(OAuthToken token)
        {
            var path = Path.Combine(Directory.GetCurrentDirectory()!, TOKEN_FILE);

            try
            {
                string json = JsonSerializer.Serialize(token);
                File.WriteAllText(path, json);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Warning, unable to save token: {ex.Message}");
            }
        }

        public OAuthToken? Login(OAuthToken? token)
        {
            OAuthDeviceCode? deviceCode = null;

            token = RefreshTokenIfNecessary(token);

            while (token == null)
            {
                if (deviceCode == null)
                {
                    try
                    {
                        deviceCode = GetOAuthDeviceCode();
                        deviceCode.ExpiresAt = GetUnixTimestamp() + deviceCode.ExpiresIn;

                        Console.WriteLine("To authorize, go to:");
                        Console.WriteLine($"{deviceCode.VerificationUriComplete}");
                        Console.WriteLine($"Or enter code {deviceCode.UserCode} at {deviceCode.VerificationUri}");

                        Console.WriteLine("Waiting for authorization...");
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"Unable to get device code: {ex.Message}");
                        return null;
                    }
                }

                if (deviceCode.ExpiresAt <= GetUnixTimestamp())
                {
                    Console.WriteLine("Device code timed out!");
                    deviceCode = null;
                    continue;
                }

                try
                {
                    token = GetOAuthToken(deviceCode.DeviceCode);
                    token.ExpiresAt = GetUnixTimestamp() + token.ExpiresIn;
                }
                catch (OAuthException ex)
                {
                    if (ex.Code == "authorization_pending")
                    {
                        System.Threading.Thread.Sleep(deviceCode.Interval * 1000);
                        continue;
                    }

                    Console.WriteLine($"Authorization error: {ex.Message}");
                    return null;
                }

                break;
            }

            return token;
        }

        private OAuthDeviceCode GetOAuthDeviceCode()
        {
            Console.WriteLine("Getting device code...");

            var client = new RestClient(API_ENDPOINT);

            var request = new RestRequest("https://oauth-dev.ibroadcast.com/device/code", Method.Get);
            request.AddHeader("User-Agent", USER_AGENT);
            request.AddParameter("client_id", CLIENT_ID);
            request.AddParameter("scope", "user.account:read user.upload");

            var response = client.Execute(request);

            if (!response.IsSuccessful)
            {
                var json = JsonSerializer.Deserialize<OAuthError>(response.Content!)!;
                throw new OAuthException(json.Error, json.ErrorDescription);
            }

            return JsonSerializer.Deserialize<OAuthDeviceCode>(response.Content!)!;
        }

        private OAuthToken GetOAuthToken(string code)
        {
            var client = new RestClient(API_ENDPOINT);

            var request = new RestRequest("https://oauth-dev.ibroadcast.com/token", Method.Post);
            request.AddHeader("User-Agent", USER_AGENT);
            request.AddParameter("client_id", CLIENT_ID);
            request.AddParameter("grant_type", "device_code");
            request.AddParameter("device_code", code);

            var response = client.Execute(request);

            if (!response.IsSuccessful)
            {
                var json = JsonSerializer.Deserialize<OAuthError>(response.Content!)!;
                throw new OAuthException(json.Error, json.ErrorDescription);
            }

            return JsonSerializer.Deserialize<OAuthToken>(response.Content!)!;
        }

        private OAuthToken RefreshToken(string refreshToken)
        {
            Console.WriteLine("Refreshing token...");

            var client = new RestClient(API_ENDPOINT);

            var request = new RestRequest("https://oauth-dev.ibroadcast.com/token", Method.Post);
            request.AddHeader("User-Agent", USER_AGENT);
            request.AddParameter("client_id", CLIENT_ID);
            request.AddParameter("grant_type", "refresh_token");
            request.AddParameter("refresh_token", refreshToken);

            var response = client.Execute(request);

            if (!response.IsSuccessful)
            {
                var json = JsonSerializer.Deserialize<OAuthError>(response.Content!)!;
                throw new OAuthException(json.Error, json.ErrorDescription);
            }

            return JsonSerializer.Deserialize<OAuthToken>(response.Content!)!;
        }

        private OAuthToken? RefreshTokenIfNecessary(OAuthToken? token)
        {
            if (token == null) return null;

            if (token.ExpiresAt <= GetUnixTimestamp())
            {
                try
                {
                    var refreshedToken = RefreshToken(token.RefreshToken);
                    refreshedToken.ExpiresAt = GetUnixTimestamp() + refreshedToken.ExpiresAt;
                    SaveToken(refreshedToken);
                    return refreshedToken;
                }
                catch (OAuthException ex)
                {
                    Console.WriteLine($"Authorization error, please log in again: {ex.Message}");
                    return null;
                }
            }

            return token;
        }

        private long GetUnixTimestamp()
        {
            return DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        }

        private void status(OAuthToken token)
        {
            try
            {
                Console.WriteLine("Fetching account info...");

                var userdetails = new Dictionary<string, object>();
                userdetails.Add("mode", "status");
                userdetails.Add("version", VERSION);
                userdetails.Add("client", CLIENT);
                userdetails.Add("user-agent", USER_AGENT);
                userdetails.Add("supported_types", 1);

                var client = new RestClient(API_ENDPOINT);
                RestRequest request = new RestRequest("/", Method.Post);
                request.RequestFormat = DataFormat.Json;
                request.AddHeader("Content-Type", JSON_CONTENT_TYPE);
                request.AddHeader("User-Agent", USER_AGENT);
                request.AddHeader("Authorization", $"{token.TokenType} {token.AccessToken}");
                request.AddParameter("text/json", userdetails, ParameterType.RequestBody);

                var response = client.Execute(request);

                if (System.Net.HttpStatusCode.OK != response.StatusCode)
                {
                    Console.WriteLine("{0} failed.\nresponse.Code: {1}\nresponse.StatusDescription: {2}", System.Reflection.MethodBase.GetCurrentMethod()?.Name, response.StatusCode, response.StatusDescription);
                    Environment.Exit(-1);
                }

                bool result = false;
                var dynJson = response.Content == null ? null : JsonSerializer.Deserialize<JsonObject>(response.Content);

                result = dynJson?["result"]?.GetValue<bool>() ?? false;

                if (!result)
                {
                    Console.WriteLine("{0}", dynJson?["message"]?.GetValue<string>());
                    Environment.Exit(-1);
                }

                var supported = dynJson?["supported"];

                if (supported != null)
                {
                    foreach (var jObj in supported.AsArray())
                    {
                        if (jObj == null)
                        {
                            continue;
                        }

                        String ext = Path.GetExtension(jObj["extension"].GetValue<string>());
                        if (!extensions.Contains(ext)) //is extension unique? (ex: .flac x 3 in response)
                        {
                            extensions.Add(ext);
                        }
                    }
                }

                Console.WriteLine("Status successful");
            }
            catch (Exception e)
            {
                Console.WriteLine("{0} failed. Exception: {1}", System.Reflection.MethodBase.GetCurrentMethod()?.Name, e.Message);
                Environment.Exit(-1);
            }
        }

        private void getMD5(OAuthToken token)
        {
            try
            {
                var client = new RestClient(SYNC_ENDPOINT);
                RestRequest request = new RestRequest("/", Method.Post);
                request.AddHeader("Content-Type", URL_CONTENT_TYPE);
                request.AddHeader("User-Agent", USER_AGENT);
                request.AddHeader("Authorization", $"{token.TokenType} {token.AccessToken}");

                var response = client.Execute(request);

                if (System.Net.HttpStatusCode.OK != response.StatusCode)
                {
                    Console.WriteLine("{0} failed.\nresponse.Code: {1}\nresponse.StatusDescription: {2}", 
                                      System.Reflection.MethodBase.GetCurrentMethod()?.Name, response.StatusCode, response.StatusDescription);
                    Environment.Exit(-1);
                }

                bool result = false;
                var dynJson = JsonSerializer.Deserialize<JsonObject>(response.Content ?? "{}");

                result = dynJson?["result"]?.GetValue<bool>() ?? false;

                if (!result)
                {
                    Console.WriteLine("{0}", dynJson?["message"]?.GetValue<string>() ?? "");
                    Environment.Exit(-1);
                }

                var jsonArray = dynJson?["md5"]?.AsArray();

                if (jsonArray != null)
                {
                    foreach (var jVal in jsonArray)
                    {
                        if (jVal != null)
                        {
                            md5s.Add(jVal.GetValue<string>());
                        }
                    }
                }
            }

            catch (Exception e)
            {
                Console.WriteLine("{0} failed. Exception: {1}", System.Reflection.MethodBase.GetCurrentMethod()?.Name, e.Message);
                Environment.Exit(-1);
            }
        }

        private List<FileInfo> loadMediaFilesQ(String dir)
        {
            try
            {
                return (from file in new DirectoryInfo(dir).EnumerateFiles("*.*", SearchOption.AllDirectories)
                              where extensions.Contains(file.Extension.ToLower())
                              select file).ToList();
            }
            catch (Exception e)
            {
                Console.WriteLine("{0} failed. Exception: {1}", System.Reflection.MethodBase.GetCurrentMethod()?.Name, e.Message);
                Environment.Exit(-1);
            }

            return new List<FileInfo>();
        }

        private void executeOptions(OAuthToken token)
        {
            try
            {
                Console.WriteLine("\nFound {0} files. Press 'L' for listing and 'U' for uploading", mediaFilesQ.Count);
                String option = Console.ReadLine() ?? "";

                if (option.ToUpper().StartsWith("L"))
                {
                    Console.WriteLine("\nListing found, supported files:");
                    foreach (FileInfo file in mediaFilesQ)
                    {
                        Console.WriteLine(" - " + file.FullName);
                    }
                    Console.WriteLine("\nPress 'U' to start the upload if this looks reasonable");
                    option = Console.ReadLine() ?? "";
                }

                if (option.ToUpper().StartsWith("U"))
                {
                    Console.WriteLine("Starting upload");

                    String cksum;
                    int nrUploadedFiles = 0;
                    foreach (FileInfo file in mediaFilesQ)
                    {
                        Console.WriteLine("Uploading {0}", file.Name);

                        cksum = GetMD5HashFromFile(file.FullName);
                        if (md5s.Contains(cksum))
                        {
                            Console.WriteLine("skipping, already uploaded");
                            continue;
                        }

                        try
                        {
                            if (uploadMediaFile(file, token))
                            {
                                nrUploadedFiles++;
                            }
                        } catch (OAuthException ex)
                        {
                            if (ex.Code == "unauthorized")
                            {
                                token = RefreshTokenIfNecessary(token)!;
                                if (uploadMediaFile(file, token))
                                {
                                    nrUploadedFiles++;
                                }
                            }
                        }
                    }
                    Console.WriteLine("\nDone. {0} files were uploaded.", nrUploadedFiles);
                }
                else
                {
                    Console.WriteLine("Aborted.");
                }
            }
            catch (Exception e)
            {
                Console.WriteLine("{0} failed. Exception: {1}", System.Reflection.MethodBase.GetCurrentMethod()?.Name, e.Message);
                Environment.Exit(-1);
            }
        }

        private bool uploadMediaFile(FileInfo file, OAuthToken token)
        {
            try
            {
                byte[] data = File.ReadAllBytes(file.FullName);
                var client = new RestClient(SYNC_ENDPOINT);

                RestRequest request = new RestRequest("/", Method.Post);
                request.AlwaysMultipartFormData = true;
                request.AddParameter("file_path", file.FullName);
                request.AddParameter("method", CLIENT);
                request.AddFile("file", data, file.Name);

                request.AddHeader("User-Agent", USER_AGENT);
                request.AddHeader("Authorization", $"{token.TokenType} {token.AccessToken}");

                var response = client.Execute(request);

                // Retry one time if 401, attempt token refresh
                if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized) {
                    throw new OAuthException("unauthorized", "Unable to authorize");
                }

                if (System.Net.HttpStatusCode.OK != response.StatusCode)
                {
                    Console.WriteLine("uploadMediaFile {0} Failed.\nresponse.Code: {1}\nresponse.StatusDescription: {2}\nresponse.ErrorMessage: {3}", file.Name, response.StatusCode, response.StatusDescription, response.ErrorMessage);
                    return false;
                }

                bool result = false;
                var dynJson = response.Content == null ? null : JsonSerializer.Deserialize<JsonObject>(response.Content);

                result = dynJson?["result"]?.GetValue<bool>() ?? false;

                if (!result)
                {
                    Console.WriteLine("{0}", dynJson?["message"]?.GetValue<string>());
                }

                return result;

            }
            catch (Exception e)
            {
                Console.WriteLine("Failed! Exception: {0}", e.Message);
            }
            return false;
        }

        private static string GetMD5HashFromFile(string fileName)
        {
            try
            {
                FileStream file = new FileStream(fileName, FileMode.Open);
                System.Security.Cryptography.MD5 md5 = new System.Security.Cryptography.MD5CryptoServiceProvider();
                byte[] retVal = md5.ComputeHash(file);
                file.Close();

                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < retVal.Length; i++)
                {
                    sb.Append(retVal[i].ToString("x2"));
                }
                return sb.ToString();
            }
            catch (Exception e)
            {
                Console.WriteLine("{0} failed. Exception: {1}", System.Reflection.MethodBase.GetCurrentMethod()?.Name, e.Message);
                Environment.Exit(-1);
            }

            return String.Empty;
        }

    }
}
