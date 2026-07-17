using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexProviderBridge;

internal sealed record BridgeSettings(string RealCodexPath, string RealCodexSha256, string[] RealCodexPrefixArgs);

internal static class Program
{
    private const string SettingsFileName = "codex-provider-bridge.json";
    private const string ActiveEnvironmentVariable = "CODEX_PROVIDER_BRIDGE_ACTIVE";
    private static ChildProcessJob? processLifetimeJob;

    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (Environment.GetEnvironmentVariable(ActiveEnvironmentVariable) == "1")
            {
                throw new InvalidOperationException("Recursive Codex provider bridge launch was rejected.");
            }

            Console.InputEncoding = new UTF8Encoding(false);
            // Joining the bridge itself before Process.Start makes all later
            // Codex descendants inherit the kill-on-close job atomically.
            // Keep the handle rooted until process teardown; closing it early
            // would intentionally terminate this process as a job member.
            processLifetimeJob = ChildProcessJob.CreateForCurrentProcess();
            var settings = LoadSettings();
            using var child = StartCodex(settings, args);
            return await ProxyAsync(child);
        }
        catch (Exception exception)
        {
            await Console.Error.WriteLineAsync($"Codex provider bridge error: {exception.Message}");
            return 2;
        }
    }

    private static BridgeSettings LoadSettings()
    {
        var settingsPath = Path.Combine(AppContext.BaseDirectory, SettingsFileName);
        if (!File.Exists(settingsPath))
        {
            throw new FileNotFoundException($"Bridge settings file is missing: {settingsPath}");
        }

        using var document = JsonDocument.Parse(File.ReadAllText(settingsPath));
        var root = document.RootElement;
        var realCodexPath = root.TryGetProperty("realCodexPath", out var pathElement)
            ? pathElement.GetString()?.Trim()
            : null;
        if (string.IsNullOrWhiteSpace(realCodexPath) || !Path.IsPathFullyQualified(realCodexPath))
        {
            throw new InvalidDataException("Bridge settings realCodexPath must be an absolute path.");
        }

        var fullRealPath = Path.GetFullPath(realCodexPath);
        if (!File.Exists(fullRealPath))
        {
            throw new FileNotFoundException($"Configured Codex executable is missing: {fullRealPath}");
        }
        RejectRecursivePath(fullRealPath);
        var expectedHash = ReadSha256(root);
        VerifySha256(fullRealPath, expectedHash);

        var prefixArgs = ReadStringArray(root, "realCodexPrefixArgs");
        return new BridgeSettings(fullRealPath, expectedHash, prefixArgs);
    }

    private static string ReadSha256(JsonElement root)
    {
        var hash = root.TryGetProperty("realCodexSha256", out var hashElement)
            ? hashElement.GetString()?.Trim().ToUpperInvariant()
            : null;
        if (hash is null || hash.Length != 64 || hash.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new InvalidDataException("Bridge settings realCodexSha256 must be a 64-character SHA256 hash.");
        }
        return hash;
    }

    private static void VerifySha256(string path, string expectedHash)
    {
        using var stream = File.OpenRead(path);
        var actualHash = Convert.ToHexString(SHA256.HashData(stream));
        if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Configured Codex executable hash does not match bridge settings.");
        }
    }

    private static string[] ReadStringArray(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element))
        {
            return [];
        }
        if (element.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException($"Bridge settings {propertyName} must be an array.");
        }

        return element.EnumerateArray().Select(item =>
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                throw new InvalidDataException($"Bridge settings {propertyName} entries must be strings.");
            }
            return item.GetString() ?? string.Empty;
        }).ToArray();
    }

    private static void RejectRecursivePath(string realCodexPath)
    {
        var bridgePath = Environment.ProcessPath;
        if (bridgePath is null)
        {
            return;
        }

        if (string.Equals(
                Path.GetFullPath(bridgePath),
                realCodexPath,
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The bridge cannot launch itself as the real Codex executable.");
        }
    }

    private static Process StartCodex(BridgeSettings settings, IReadOnlyList<string> forwardedArgs)
    {
        var startInfo = new ProcessStartInfo(settings.RealCodexPath)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in settings.RealCodexPrefixArgs)
        {
            startInfo.ArgumentList.Add(argument);
        }
        foreach (var argument in forwardedArgs)
        {
            startInfo.ArgumentList.Add(argument);
        }
        startInfo.Environment.Remove("CODEX_CLI_PATH");
        startInfo.Environment[ActiveEnvironmentVariable] = "1";

        return Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to start the configured Codex executable.");
    }

    private static async Task<int> ProxyAsync(Process child)
    {
        var inputTask = PumpInputAsync(child.StandardInput);
        var outputTask = child.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
        var errorTask = child.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
        var exitTask = child.WaitForExitAsync();

        var firstCompleted = await Task.WhenAny(inputTask, exitTask);
        if (firstCompleted == inputTask)
        {
            await inputTask;
            child.StandardInput.Close();
            await exitTask;
        }

        await Task.WhenAll(outputTask, errorTask);
        return child.ExitCode;
    }

    private static async Task PumpInputAsync(StreamWriter childInput)
    {
        string? line;
        while ((line = await Console.In.ReadLineAsync()) is not null)
        {
            await childInput.WriteLineAsync(TransformRequest(line));
            await childInput.FlushAsync();
        }
    }

    private static string TransformRequest(string line)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(line);
        }
        catch (JsonException)
        {
            return line;
        }

        if (root is not JsonObject message ||
            message["method"] is not JsonValue methodValue ||
            !methodValue.TryGetValue<string>(out var method) ||
            method != "thread/list")
        {
            return line;
        }

        var parameters = message["params"] as JsonObject ?? new JsonObject();
        parameters["modelProviders"] = new JsonArray();
        message["params"] = parameters;
        return message.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
    }
}
