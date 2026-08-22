param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $AssemblyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $AssemblyPath).Path
Add-Type -AssemblyName System.Reflection.Metadata

$stream = [System.IO.File]::OpenRead($resolvedPath)
$peReader = $null

try {
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    if (-not $peReader.HasMetadata) {
        throw "Release artifact is not a managed assembly: $resolvedPath"
    }

    $metadata = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)

    $references = @(
        foreach ($handle in $metadata.AssemblyReferences) {
            $reference = $metadata.GetAssemblyReference($handle)
            $metadata.GetString($reference.Name)
        }
    )

    if ($references -contains 'OverlayAPI.LazerProtocol') {
        throw 'ILRepack verification failed: the release artifact still references OverlayAPI.LazerProtocol externally.'
    }

    $protocolTypes = @(
        foreach ($handle in $metadata.TypeDefinitions) {
            $type = $metadata.GetTypeDefinition($handle)
            if ($metadata.GetString($type.Namespace) -eq 'OverlayAPI.LazerProtocol') {
                $metadata.GetString($type.Name)
            }
        }
    )

    if ($protocolTypes.Count -eq 0) {
        throw 'ILRepack verification failed: the release artifact contains no OverlayAPI.LazerProtocol types.'
    }

    Write-Output "::notice::Verified ILRepack output: $($protocolTypes.Count) protocol types are merged with no external protocol assembly reference."
}
finally {
    if ($null -ne $peReader) {
        $peReader.Dispose()
    }
    $stream.Dispose()
}
