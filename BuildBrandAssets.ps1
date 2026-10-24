# Run with Windows PowerShell 5.1. Uses the panel's vector mark as the icon source.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$assets=Join-Path $PSScriptRoot 'assets'
[void][IO.Directory]::CreateDirectory($assets)
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MonitorInput.ps1'))
$match=[regex]::Match($source,'(?s)<DrawingImage x:Key="BrandLogo">(.*?)</DrawingImage>')
if(-not $match.Success) { throw 'BrandLogo vector resource was not found.' }
$drawing=[Windows.Markup.XamlReader]::Parse(('<DrawingImage xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">'+$match.Groups[1].Value+'</DrawingImage>'))
$sizes=@(16,20,24,32,40,48,64,128,256)
$frames=[Collections.Generic.List[byte[]]]::new()
foreach($size in $sizes) {
    $visual=[Windows.Media.DrawingVisual]::new()
    $context=$visual.RenderOpen()
    $context.PushTransform([Windows.Media.ScaleTransform]::new($size/64.0,$size/64.0))
    $context.DrawRoundedRectangle([Windows.Media.BrushConverter]::new().ConvertFromString('#171D30'),$null,[Windows.Rect]::new(0,0,64,64),14,14)
    $context.DrawImage($drawing,[Windows.Rect]::new(0,0,64,64))
    $context.Pop(); $context.Close()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($size,$size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $memory=[IO.MemoryStream]::new()
    try { $encoder.Save($memory); $frames.Add($memory.ToArray()) } finally { $memory.Dispose() }
    if($size -eq 256) { [IO.File]::WriteAllBytes((Join-Path $assets 'logo.png'),$frames[$frames.Count-1]) }
}
$output=[IO.File]::Create((Join-Path $assets 'app.ico'))
$writer=[IO.BinaryWriter]::new($output)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset=6+16*$sizes.Count
    for($i=0;$i -lt $sizes.Count;$i++) {
        $dimension=if($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
        $offset+=$frames[$i].Length
    }
    foreach($frame in $frames) { $writer.Write([byte[]]$frame) }
} finally { $writer.Dispose(); $output.Dispose() }
$svg=@'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <title>Display Studio</title>
  <rect x="36" y="20" width="12" height="20" rx="2" fill="#A7BAFF" fill-opacity=".196"/>
  <path d="M18 16H46Q52 16 52 22V38Q52 44 46 44H18Q12 44 12 38V22Q12 16 18 16Z" stroke="#DCE5FF" stroke-width="3.5" stroke-linejoin="round"/>
  <path d="M33 23V37M32 44V50M25 50H39" stroke="#A7BAFF" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
'@
[IO.File]::WriteAllText((Join-Path $assets 'logo.svg'),$svg,[Text.UTF8Encoding]::new($false))
Write-Output 'Built vector logo, PNG preview, and nine-size Windows icon.'
