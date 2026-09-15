using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace CodexBridgeTest
{
    public static class AppToolsServer
    {
        private static readonly object LogLock = new object();

        public static void Run(
            string pipeName,
            string logPath,
            string resultPath,
            string readyPath)
        {
            NamedPipeServerStream server = NewServer(pipeName);
            File.WriteAllText(readyPath, "ready");
            while (true)
            {
                server.WaitForConnection();
                NamedPipeServerStream connected = server;
                server = NewServer(pipeName);
                ThreadPool.QueueUserWorkItem(delegate
                {
                    try
                    {
                        Handle(connected, pipeName, logPath, resultPath);
                    }
                    finally
                    {
                        connected.Dispose();
                    }
                });
            }
        }

        private static NamedPipeServerStream NewServer(string pipeName)
        {
            return new NamedPipeServerStream(
                pipeName,
                PipeDirection.InOut,
                NamedPipeServerStream.MaxAllowedServerInstances,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous);
        }

        private static void Handle(
            Stream stream,
            string pipeName,
            string logPath,
            string resultPath)
        {
            JavaScriptSerializer json = new JavaScriptSerializer();
            Dictionary<string, object> request = ReadFrame(stream, json);
            string method = (string)request["method"];
            string fullPipe = @"\\.\pipe\" + pipeName;
            if (method == "tools/list")
            {
                Append(logPath, json.Serialize(new Dictionary<string, object>
                {
                    { "operation", "discover" },
                    { "candidates", new[] { fullPipe } }
                }));
                WriteFrame(stream, json.Serialize(new Dictionary<string, object>
                {
                    { "id", 1 },
                    { "jsonrpc", "2.0" },
                    { "result", new Dictionary<string, object>
                        {
                            { "tools", new[]
                                {
                                    new Dictionary<string, object>
                                    {
                                        { "name", "send_message_to_thread" },
                                        { "namespace", "codex_app" }
                                    }
                                }
                            }
                        }
                    }
                }));
                return;
            }

            Dictionary<string, object> parameters =
                (Dictionary<string, object>)request["params"];
            Dictionary<string, object> arguments =
                (Dictionary<string, object>)parameters["arguments"];
            string target = (string)arguments["threadId"];
            Append(logPath, json.Serialize(new Dictionary<string, object>
            {
                { "operation", "send" },
                { "candidates", new[] { fullPipe } },
                { "sourceTaskId", (string)parameters["threadId"] },
                { "targetTaskId", target },
                { "prompt", (string)arguments["prompt"] }
            }));

            string result = File.ReadAllText(resultPath);
            if (result == "unknown") return;
            if (result == "malformed")
            {
                WriteFrame(stream, "not json");
                return;
            }
            if (result == "rejected")
            {
                WriteFrame(stream, json.Serialize(new Dictionary<string, object>
                {
                    { "id", 1 },
                    { "jsonrpc", "2.0" },
                    { "error", new Dictionary<string, object>
                        {
                            { "message", "native rejection" }
                        }
                    }
                }));
                return;
            }

            string receipt = json.Serialize(new Dictionary<string, object>
            {
                { "threadId", target }
            });
            WriteFrame(stream, json.Serialize(new Dictionary<string, object>
            {
                { "id", 1 },
                { "jsonrpc", "2.0" },
                { "result", new Dictionary<string, object>
                    {
                        { "success", true },
                        { "contentItems", new[]
                            {
                                new Dictionary<string, object>
                                {
                                    { "type", "inputText" },
                                    { "text", receipt }
                                }
                            }
                        }
                    }
                }
            }));
        }

        private static Dictionary<string, object> ReadFrame(
            Stream stream,
            JavaScriptSerializer json)
        {
            byte[] header = ReadExactly(stream, 4);
            int size = checked((int)BitConverter.ToUInt32(header, 0));
            string payload = Encoding.UTF8.GetString(ReadExactly(stream, size));
            return json.Deserialize<Dictionary<string, object>>(payload);
        }

        private static byte[] ReadExactly(Stream stream, int size)
        {
            byte[] bytes = new byte[size];
            int offset = 0;
            while (offset < size)
            {
                int count = stream.Read(bytes, offset, size - offset);
                if (count == 0) throw new EndOfStreamException();
                offset += count;
            }
            return bytes;
        }

        private static void WriteFrame(Stream stream, string payload)
        {
            byte[] body = Encoding.UTF8.GetBytes(payload);
            byte[] header = BitConverter.GetBytes((uint)body.Length);
            stream.Write(header, 0, header.Length);
            stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        private static void Append(string path, string line)
        {
            lock (LogLock)
            {
                File.AppendAllText(path, line + Environment.NewLine);
            }
        }
    }
}
