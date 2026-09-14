param($PipeName, $LogPath, $ResultPath, $ReadyPath)

function Read-Exactly([IO.Stream]$Stream, [byte[]]$Buffer) {
  $offset = 0
  while ($offset -lt $Buffer.Length) {
    $count = $Stream.Read($Buffer, $offset, $Buffer.Length - $offset)
    if ($count -eq 0) { throw 'connection closed' }
    $offset += $count
  }
}

function Write-Frame([IO.Stream]$Stream, [string]$Payload) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
  $header = [BitConverter]::GetBytes([uint32]$bytes.Length)
  $Stream.Write($header, 0, $header.Length)
  $Stream.Write($bytes, 0, $bytes.Length)
  $Stream.Flush()
}

$fullPipe = "\\.\pipe\$PipeName"
$ready = $false
while ($true) {
  $server = [IO.Pipes.NamedPipeServerStream]::new(
    $PipeName,
    [IO.Pipes.PipeDirection]::InOut,
    1,
    [IO.Pipes.PipeTransmissionMode]::Byte,
    [IO.Pipes.PipeOptions]::Asynchronous
  )
  try {
    if (-not $ready) {
      [IO.File]::WriteAllText($ReadyPath, 'ready')
      $ready = $true
    }
    $server.WaitForConnection()
    $header = [byte[]]::new(4)
    Read-Exactly $server $header
    $size = [BitConverter]::ToUInt32($header, 0)
    $payload = [byte[]]::new($size)
    Read-Exactly $server $payload
    $request = [Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json

    if ($request.method -eq 'tools/list') {
      $record = @{ operation = 'discover'; candidates = @($fullPipe) }
      Add-Content -LiteralPath $LogPath -Value ($record | ConvertTo-Json -Compress)
      $response = @{
        id = 1
        jsonrpc = '2.0'
        result = @{
          tools = @(@{
            name = 'send_message_to_thread'
            namespace = 'codex_app'
          })
        }
      }
      Write-Frame $server ($response | ConvertTo-Json -Depth 8 -Compress)
      continue
    }

    $arguments = $request.params.arguments
    $target = $arguments.threadId
    $record = @{
      operation = 'send'
      candidates = @($fullPipe)
      sourceTaskId = $request.params.threadId
      targetTaskId = $target
      prompt = $arguments.prompt
    }
    Add-Content -LiteralPath $LogPath -Value ($record | ConvertTo-Json -Compress)

    $result = Get-Content -LiteralPath $ResultPath -Raw
    if ($result -eq 'unknown') { continue }
    if ($result -eq 'malformed') {
      Write-Frame $server 'not json'
      continue
    }
    if ($result -eq 'rejected') {
      $response = @{
        id = 1
        jsonrpc = '2.0'
        error = @{ message = 'native rejection' }
      }
      Write-Frame $server ($response | ConvertTo-Json -Depth 8 -Compress)
      continue
    }

    $receipt = @{ threadId = $target } | ConvertTo-Json -Compress
    $response = @{
      id = 1
      jsonrpc = '2.0'
      result = @{
        success = $true
        contentItems = @(@{ type = 'inputText'; text = $receipt })
      }
    }
    Write-Frame $server ($response | ConvertTo-Json -Depth 8 -Compress)
  } finally {
    $server.Dispose()
  }
}
