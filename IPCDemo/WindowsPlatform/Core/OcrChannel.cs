using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace DynaPet.Core;

public sealed record OcrResult(bool Ok, string Text, string Error);

/// A private bounded memory channel; no console handles or plaintext files needed.
public static class OcrChannel
{
    public static string NewName() => "dynapet-ocr-" + Guid.NewGuid().ToString("N");
    public static NamedPipeServerStream Create(string name) => new(name, PipeDirection.In, 1,
        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    public static async Task Send(string name, OcrResult result, CancellationToken token)
    {
        using var client = new NamedPipeClientStream(".", name, PipeDirection.Out, PipeOptions.Asynchronous);
        await client.ConnectAsync(token);
        await using var writer = new StreamWriter(client, new UTF8Encoding(false));
        await writer.WriteAsync(JsonSerializer.Serialize(result).AsMemory(), token);
        await writer.FlushAsync(token);
    }
    public static async Task<OcrResult> Receive(NamedPipeServerStream server, CancellationToken token)
    {
        await server.WaitForConnectionAsync(token);
        using var reader = new StreamReader(server, new UTF8Encoding(false, true));
        var buffer = new char[2048]; var text = new StringBuilder();
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token)) != 0)
        {
            if (text.Length + count > 65536) throw new InvalidDataException("OCR response too large");
            text.Append(buffer, 0, count);
        }
        if (text.Length == 0) throw new InvalidDataException("Empty OCR response");
        return JsonSerializer.Deserialize<OcrResult>(text.ToString()) ?? throw new InvalidDataException("Missing OCR response");
    }
}
