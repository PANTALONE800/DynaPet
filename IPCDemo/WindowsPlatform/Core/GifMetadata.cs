using System.Text;

namespace DynaPet.Core;

/// Validate structure and resource bounds before invoking the native decoder.
/// Retain raw timing/loop values: native libraries can normalize these differently.
public sealed record GifMetadata(int Width, int Height, double[] Delays, int? Repeats)
{
    public static GifMetadata Read(string file)
    {
        if (new FileInfo(file).Length > 32 * 1024 * 1024) throw new InvalidDataException("GIF 超过 32 MiB。");
        using var input = File.OpenRead(file);
        using var reader = new BinaryReader(input, Encoding.ASCII);
        byte Read() { if (input.Position >= input.Length) throw new InvalidDataException("GIF 数据不完整。"); return reader.ReadByte(); }
        byte[] Bytes(int count)
        {
            if (count < 0 || input.Length - input.Position < count) throw new InvalidDataException("GIF 数据不完整。");
            return reader.ReadBytes(count);
        }
        int Word() => Read() | Read() << 8;
        List<byte[]> Blocks()
        {
            var blocks = new List<byte[]>();
            for (var size = Read(); size != 0; size = Read()) blocks.Add(Bytes(size));
            return blocks;
        }
        void SkipBlocks() { for (var size = Read(); size != 0; size = Read()) Bytes(size); }
        var header = Encoding.ASCII.GetString(Bytes(6));
        if (header != "GIF87a" && header != "GIF89a") throw new InvalidDataException("不是 GIF。");
        var width = Word(); var height = Word(); var packed = Read(); Bytes(2);
        if (width is < 1 or > 4096 || height is < 1 or > 4096) throw new InvalidDataException("GIF 画布超过 4096×4096。");
        if ((packed & 128) != 0) Bytes(3 * (1 << ((packed & 7) + 1)));
        var delays = new List<double>(); int? repeats = null; double pendingDelay = .1;
        while (true)
        {
            switch (Read())
            {
                case 0x3b:
                    if (delays.Count == 0) throw new InvalidDataException("GIF 无帧。");
                    return new(width, height, delays.ToArray(), repeats);
                case 0x21:
                    var label = Read(); var blocks = Blocks();
                    if (label == 0xf9)
                    {
                        if (blocks.Count != 1 || blocks[0].Length != 4) throw new InvalidDataException("无效 GIF 控制块。");
                        var delay = blocks[0][1] | blocks[0][2] << 8;
                        pendingDelay = delay > 0 ? delay / 100.0 : .1;
                    }
                    else if (label == 0xff && blocks.Count >= 2 &&
                        (Encoding.ASCII.GetString(blocks[0]) is "NETSCAPE2.0" or "ANIMEXTS1.0"))
                    {
                        var loop = blocks[1];
                        if (loop.Length != 3 || loop[0] != 1) throw new InvalidDataException("无效 GIF 循环块。");
                        repeats = loop[1] | loop[2] << 8;
                    }
                    break;
                case 0x2c:
                    Bytes(4); var frameWidth = Word(); var frameHeight = Word(); packed = Read();
                    if (frameWidth < 1 || frameHeight < 1 || frameWidth > width || frameHeight > height) throw new InvalidDataException("无效 GIF 帧尺寸。");
                    if ((packed & 128) != 0) Bytes(3 * (1 << ((packed & 7) + 1)));
                    Read(); SkipBlocks(); delays.Add(pendingDelay); pendingDelay = .1;
                    if (delays.Count > 1000 || (long)width * height * delays.Count > 64_000_000) throw new InvalidDataException("GIF 解码资源超限，不会截断。");
                    break;
                default: throw new InvalidDataException("无效 GIF 块。");
            }
        }
    }
}
