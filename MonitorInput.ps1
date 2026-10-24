param(
    [ValidateSet('Gui','Probe','Read','Switch','SetBrightness','SetVolume','SetSmartImage','SelfTest')][string]$Action='Gui',
    [ValidateSet('DP','HDMI1','HDMI2','HDMI3')][string]$Source='DP',
    [ValidateRange(0,100)][int]$Value=0,
    [ValidateSet('Off','LowBlue')][string]$SmartImageMode='Off',
    [string]$MonitorId='',
    [string]$BaseDirectory=$PSScriptRoot,
    [string]$StateDirectory=''
)
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($BaseDirectory)) { throw 'BaseDirectory is required.' }
if ([string]::IsNullOrWhiteSpace($StateDirectory)) { $StateDirectory=Join-Path $env:LOCALAPPDATA 'MonitorInputPrototype' }
$script:StateDirectory=$StateDirectory
$script:ConfigPath=Join-Path $StateDirectory 'settings.json'
$script:Sources=@('DP','HDMI1','HDMI2','HDMI3')
$script:Names=@{ DP='DisplayPort'; HDMI1='HDMI 1'; HDMI2='HDMI 2'; HDMI3='HDMI 3' }
$script:ConfigWarning=''
Add-Type -Path (Join-Path $BaseDirectory 'MonitorNative.cs')

function New-DefaultConfig {
    return [ordered]@{ Version=1; MonitorId=''; Hotkeys=[ordered]@{ DP='Ctrl+Alt+0'; HDMI1='Ctrl+Alt+1'; HDMI2='Ctrl+Alt+2'; HDMI3='Ctrl+Alt+3' }; SourceValues=[ordered]@{ DP=15; HDMI1=17; HDMI2=18; HDMI3=19 } }
}
function Convert-Config($value) {
    if ($value.Version -ne 1) { throw 'Unsupported settings version.' }
    $config=New-DefaultConfig
    $config.MonitorId=[string]$value.MonitorId
    $seenHotkeys=@{}; $seenValues=@{}
    foreach($key in $script:Sources) {
        if ($null -eq $value.Hotkeys.PSObject.Properties[$key] -or $null -eq $value.SourceValues.PSObject.Properties[$key]) { throw 'Incomplete settings.' }
        $spec=[MonitorInputPrototype.Native]::ParseHotkey([string]$value.Hotkeys.$key)
        if ($spec.Text -and $seenHotkeys.ContainsKey($spec.Text)) { throw 'Duplicate shortcuts.' }
        if($spec.Text) { $seenHotkeys[$spec.Text]=$true }
        $number=0
        if(-not [int]::TryParse([string]$value.SourceValues.$key,[ref]$number) -or $number -lt 1 -or $number -gt 255 -or $seenValues.ContainsKey($number)) { throw 'Invalid input-source values.' }
        $seenValues[$number]=$true; $config.Hotkeys[$key]=$spec.Text; $config.SourceValues[$key]=$number
    }
    return $config
}
function Load-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return New-DefaultConfig }
    try { return Convert-Config (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { $script:ConfigWarning='設定檔無法讀取，已使用預設值；原檔尚未覆寫。'; return New-DefaultConfig }
}
function Save-Config($config) {
    [void][IO.Directory]::CreateDirectory($script:StateDirectory)
    if($script:ConfigWarning -and (Test-Path -LiteralPath $script:ConfigPath)) {
        [IO.File]::Copy($script:ConfigPath,($script:ConfigPath+'.backup-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')), $false)
        $script:ConfigWarning=''
    }
    $temporary=$script:ConfigPath+'.tmp-'+$PID
    try {
        [IO.File]::WriteAllText($temporary,($config | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
        if([IO.File]::Exists($script:ConfigPath)) { [IO.File]::Replace($temporary,$script:ConfigPath,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$script:ConfigPath) }
    } finally { if([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Write-Log([string]$message) {
    try {
        [void][IO.Directory]::CreateDirectory($script:StateDirectory)
        $path=Join-Path $script:StateDirectory 'activity.log'
        if([IO.File]::Exists($path) -and ([IO.FileInfo]$path).Length -gt 262144) { [IO.File]::Copy($path,($path+'.previous'),$true); [IO.File]::WriteAllText($path,'') }
        [IO.File]::AppendAllText($path,([DateTimeOffset]::Now.ToString('o')+' '+$message+[Environment]::NewLine),[Text.Encoding]::UTF8)
    } catch { }
}
function Source-Name([int]$value) {
    foreach($key in $script:Sources) { if($script:Config.SourceValues[$key] -eq $value) { return $script:Names[$key] } }
    if($value -lt 0) { return '無法讀取' }
    return ('未知來源 0x{0:X2}' -f $value)
}
function Get-ConnectionSnapshot($result,[string]$selectedId) {
    $ports=@{ DP='接線狀態未知'; HDMI1='接線狀態未知'; HDMI2='接線狀態未知'; HDMI3='接線狀態未知' }
    if(-not $result -or -not $result.ConnectionScanSucceeded) { return [pscustomobject]@{ Ports=$ports; Summary='無法讀取本機連線；各接孔狀態未知。' } }
    $available=@($result.Connections | Where-Object Available)
    $selectedPath=$selectedId -replace '\|\d+$',''
    foreach($connection in $available) {
        if($connection.MonitorPath -eq $selectedPath -and $connection.Technology -eq 'DisplayPort') { $ports.DP='本機已偵測' }
    }
    $dp=@($available | Where-Object { $_.Technology -eq 'DisplayPort' })
    $hdmi=@($available | Where-Object { $_.Technology -eq 'HDMI' })
    $lines=@()
    if($dp.Count -gt 0) { $lines+='DisplayPort：本機已偵測 '+$dp.Count+' 個連線。' }
    else { $lines+='DisplayPort：本機尚未偵測到連線。' }
    if($hdmi.Count -gt 0) { $lines+='HDMI：本機已偵測 '+$hdmi.Count+' 個連線，但無法辨識螢幕端的 HDMI 1／2／3。' }
    else { $lines+='HDMI：本機尚未偵測到連線；不代表 HDMI 接孔未接線。' }
    return [pscustomobject]@{ Ports=$ports; Summary=($lines -join [Environment]::NewLine) }
}
$script:Config=Load-Config

if($Action -eq 'SelfTest') {
    $checks=[Collections.Generic.List[object]]::new()
    function Check($name,[bool]$passed) { $checks.Add([pscustomobject]@{ Name=$name; Passed=$passed }) }
    Check 'Default shortcut normalization' ([MonitorInputPrototype.Native]::ParseHotkey('alt+ctrl+1').Text -eq 'Ctrl+Alt+1')
    Check 'Disabled shortcut' ([MonitorInputPrototype.Native]::ParseHotkey('').Key -eq 0)
    $invalid=$false; try { [void][MonitorInputPrototype.Native]::ParseHotkey('Ctrl+Alt+1+2') } catch { $invalid=$true }; Check 'Reject multiple primary keys' $invalid
    $invalid=$false; try { [void][MonitorInputPrototype.Native]::ParseHotkey('Shift+A') } catch { $invalid=$true }; Check 'Reject unmodified typing shortcut' $invalid
    $testConfig=New-DefaultConfig; $testConfig.Hotkeys.HDMI2='Ctrl+Alt+Shift+F12'; $testConfig.SourceValues.HDMI3=20
    $restored=Convert-Config ($testConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
    Check 'Config round trip' ($restored.Hotkeys.HDMI2 -eq 'Ctrl+Alt+Shift+F12' -and $restored.SourceValues.HDMI3 -eq 20)
    $testConfig.Hotkeys.HDMI2=$testConfig.Hotkeys.DP
    $invalid=$false; try { [void](Convert-Config ($testConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json)) } catch { $invalid=$true }; Check 'Reject duplicate hotkeys' $invalid
    $testConfig=New-DefaultConfig; $testConfig.SourceValues.HDMI2=256
    $invalid=$false; try { [void](Convert-Config ($testConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json)) } catch { $invalid=$true }; Check 'Reject out-of-range source value' $invalid
    $registered=$false
    foreach($key in @('F24','F23','F22')) {
        $combo='Ctrl+Alt+Shift+'+$key
        if([MonitorInputPrototype.Native]::Bind([IntPtr]::Zero,25001,$combo) -eq 0) {
            $registered=$true
            try { Check 'Win32 detects hotkey conflict' ([MonitorInputPrototype.Native]::Bind([IntPtr]::Zero,25002,$combo) -ne 0) }
            finally { [MonitorInputPrototype.Native]::Unbind([IntPtr]::Zero,25002); [MonitorInputPrototype.Native]::Unbind([IntPtr]::Zero,25001) }
            $again=[MonitorInputPrototype.Native]::Bind([IntPtr]::Zero,25002,$combo)
            try { Check 'Hotkey released on unregister' ($again -eq 0) } finally { [MonitorInputPrototype.Native]::Unbind([IntPtr]::Zero,25002) }
            break
        }
    }
    Check 'Hotkey registration available' $registered
    $checks | ConvertTo-Json -Depth 4
    if(@($checks | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
    return
}
if($Action -ne 'Gui') {
    $result=[MonitorInputPrototype.Native]::Begin('discover','',0).GetAwaiter().GetResult()
    if($Action -eq 'Probe') { $result | ConvertTo-Json -Depth 6; return }
    if(-not $MonitorId) { $MonitorId=$script:Config.MonitorId }
    if(-not $MonitorId) {
        $candidates=@($result.Monitors | Where-Object IsPhilips)
        if($candidates.Count -eq 1) { $MonitorId=$candidates[0].Id }
    }
    if(-not $MonitorId) { throw 'Select an unambiguous Philips 498P9Z monitor first.' }
    if($Action -in @('SetBrightness','SetVolume') -and -not $PSBoundParameters.ContainsKey('Value')) { throw 'SetBrightness and SetVolume require an explicit -Value from 0 to 100.' }
    if($Action -eq 'SetSmartImage' -and -not $PSBoundParameters.ContainsKey('SmartImageMode')) { throw 'SetSmartImage requires an explicit -SmartImageMode Off or LowBlue.' }
    $operation=switch($Action) { 'Switch' { 'switch' } 'SetBrightness' { 'brightness' } 'SetVolume' { 'volume' } 'SetSmartImage' { 'smartimage' } default { 'read' } }
    $requested=if($Action -in @('SetBrightness','SetVolume')) { $Value } elseif($Action -eq 'SetSmartImage') { if($SmartImageMode -eq 'LowBlue') { 11 } else { 0 } } else { $script:Config.SourceValues[$Source] }
    $result=[MonitorInputPrototype.Native]::Begin($operation,$MonitorId,$requested).GetAwaiter().GetResult()
    $result | ConvertTo-Json -Depth 6
    return
}

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$created=$false
$script:Mutex=[Threading.Mutex]::new($true,'Local\Philips498P9ZInputPrototype',[ref]$created)
if(-not $created) { [void][Windows.MessageBox]::Show('工具已在執行，請查看已開啟或最小化的視窗。','螢幕輸入切換'); $script:Mutex.Dispose(); return }
$script:Task=$null; $script:Busy=$false; $script:Pending=''; $script:Registered=@{}; $script:HotkeyNotes=@{}; $script:MonitorRecords=@(); $script:Closed=$false
[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="螢幕控制 · Philips 498P9Z" Width="440" Height="460" MinWidth="400" MinHeight="340" WindowStartupLocation="CenterScreen" Background="#111521" Foreground="#EFF2FC" FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
 <Window.Resources>
  <DrawingImage x:Key="BrandLogo"><DrawingImage.Drawing><DrawingGroup>
   <GeometryDrawing Brush="Transparent"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,64,64"/></GeometryDrawing.Geometry></GeometryDrawing>
   <GeometryDrawing Brush="#32A7BAFF"><GeometryDrawing.Geometry><RectangleGeometry Rect="36,20,12,20" RadiusX="2" RadiusY="2"/></GeometryDrawing.Geometry></GeometryDrawing>
   <GeometryDrawing Geometry="M18,16 H46 Q52,16 52,22 V38 Q52,44 46,44 H18 Q12,44 12,38 V22 Q12,16 18,16 Z"><GeometryDrawing.Pen><Pen Brush="#DCE5FF" Thickness="3.5" LineJoin="Round"/></GeometryDrawing.Pen></GeometryDrawing>
   <GeometryDrawing Geometry="M33,23 V37 M32,44 V50 M25,50 H39"><GeometryDrawing.Pen><Pen Brush="#A7BAFF" Thickness="3.5" StartLineCap="Round" EndLineCap="Round" LineJoin="Round"/></GeometryDrawing.Pen></GeometryDrawing>
  </DrawingGroup></DrawingImage.Drawing></DrawingImage>
  <SolidColorBrush x:Key="Muted" Color="#9FAAC4"/>
  <Style x:Key="PageScroll" TargetType="ScrollViewer"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollViewer"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" CanContentScroll="{TemplateBinding CanContentScroll}" Margin="{TemplateBinding Padding}"/><ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="1" Orientation="Vertical" Width="8" Minimum="0" Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}" Value="{Binding VerticalOffset, RelativeSource={RelativeSource TemplatedParent}, Mode=OneWay}" Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/></Grid></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ScrollBar"><Setter Property="MinWidth" Value="0"/><Setter Property="Width" Value="8"/><Setter Property="Background" Value="Transparent"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True"><Track.DecreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border x:Name="ScrollThumb" Background="#4A8390AD" CornerRadius="3" Margin="2,3"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ScrollThumb" Property="Background" Value="#9F8390AD"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="Glass" TargetType="Border"><Setter Property="Background" Value="#0CFFFFFF"/><Setter Property="BorderBrush" Value="#19FFFFFF"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="14"/><Setter Property="Padding" Value="12"/></Style>
  <Style TargetType="Button">
   <Setter Property="Background" Value="#10FFFFFF"/><Setter Property="Foreground" Value="#EFF2FC"/><Setter Property="BorderBrush" Value="#22FFFFFF"/><Setter Property="Padding" Value="14,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="36"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="BorderBrush" Value="#91A9E7"/><Setter TargetName="Surface" Property="Background" Value="#304C689C"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.65"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.35"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Surface" Property="BorderBrush" Value="#B1C6FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TextBox"><Setter Property="Background" Value="#2410182B"/><Setter Property="Foreground" Value="#EFF2FC"/><Setter Property="BorderBrush" Value="#26FFFFFF"/><Setter Property="Padding" Value="9,7"/><Setter Property="CaretBrush" Value="#B1C6FF"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
  <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="#EDF2FF"/><Setter Property="Padding" Value="12,10"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem"><Border x:Name="ItemSurface" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="6"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="#35496F"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="#2C3E62"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ComboBox"><Setter Property="Foreground" Value="#EFF2FC"/><Setter Property="Background" Value="#0AFFFFFF"/><Setter Property="BorderBrush" Value="#26FFFFFF"/><Setter Property="MinHeight" Value="38"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
   <ToggleButton x:Name="DropToggle" Focusable="False" IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" ClickMode="Press"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="ComboSurface" CornerRadius="9" BorderThickness="1" BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}" Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"><Path Data="M 0 0 L 4 4 L 8 0" Stroke="#9FAAC4" StrokeThickness="1.5" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ComboSurface" Property="BorderBrush" Value="#91A9E7"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template></ToggleButton>
   <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" Margin="12,7,34,7" VerticalAlignment="Center" IsHitTestVisible="False"/>
   <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"><Border Background="#20283D" BorderBrush="#465675" BorderThickness="1" CornerRadius="10" Padding="5" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" Margin="0,5,0,0"><ScrollViewer MaxHeight="240"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer></Border></Popup>
   </Grid><ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="#B1C6FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="Slider"><Setter Property="Focusable" Value="True"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider"><Grid Height="32" Background="{TemplateBinding Background}"><Track x:Name="PART_Track" VerticalAlignment="Center"><Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="4" Background="#A7BAFF" CornerRadius="2"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="4" Background="#29FFFFFF" CornerRadius="2"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton><Track.Thumb><Thumb Width="16" Height="24"><Thumb.Template><ControlTemplate TargetType="Thumb"><Grid><Ellipse Width="14" Height="14" Fill="#EDF2FF"><Ellipse.Effect><DropShadowEffect Color="#798FFF" BlurRadius="10" ShadowDepth="0" Opacity="0.45"/></Ellipse.Effect></Ellipse><Ellipse Width="4" Height="4" Fill="#8D9FD6"/></Grid></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Grid><ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.28"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="Background" Value="#306D88D0"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="Expander"><Setter Property="Foreground" Value="#AAB5CF"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Expander"><StackPanel><ToggleButton IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" HorizontalContentAlignment="Stretch" Foreground="{TemplateBinding Foreground}" Cursor="Hand"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="Transparent" Padding="0,10"><DockPanel><Path x:Name="Chevron" DockPanel.Dock="Right" Data="M 0 0 L 4 4 L 8 0" Width="8" Height="5" Stroke="#9FAAC4" StrokeThickness="1.4" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/><ContentPresenter/></DockPanel></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Chevron" Property="RenderTransform"><Setter.Value><RotateTransform Angle="180"/></Setter.Value></Setter></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#EDF2FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template><ContentPresenter Content="{TemplateBinding Header}"/></ToggleButton><ContentPresenter x:Name="ExpandedContent" ContentSource="Content" Visibility="Collapsed"/></StackPanel><ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="ExpandedContent" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Grid ClipToBounds="True">
  <Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#171D30" Offset="0"/><GradientStop Color="#111521" Offset="0.55"/><GradientStop Color="#1C1B30" Offset="1"/></LinearGradientBrush></Grid.Background>
  <Canvas IsHitTestVisible="False"><Ellipse Width="400" Height="350" Fill="#2525477F" Canvas.Left="-130" Canvas.Top="-130"><Ellipse.Effect><BlurEffect Radius="90"/></Ellipse.Effect></Ellipse><Ellipse Width="350" Height="400" Fill="#1C66529B" Canvas.Left="460" Canvas.Top="320"><Ellipse.Effect><BlurEffect Radius="100"/></Ellipse.Effect></Ellipse></Canvas>
  <ScrollViewer Style="{StaticResource PageScroll}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0" Focusable="False">
   <StackPanel Margin="14,12,14,10">
    <Grid Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center"><Image x:Name="BrandMark" Source="{StaticResource BrandLogo}" Width="28" Height="28" Margin="0,0,7,0" ToolTip="Display Studio" AutomationProperties.Name="Display Studio 標誌"/><TextBlock Text="Philips 498P9Z" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center"><Border Background="#12B3C8FF" BorderBrush="#20B3C8FF" BorderThickness="1" CornerRadius="12" Padding="8,5" VerticalAlignment="Center"><StackPanel Orientation="Horizontal"><Ellipse Width="5" Height="5" Fill="#A7BAFF" Margin="0,0,7,0"/><TextBlock x:Name="ConnectionBadge" Text="偵測中" Foreground="#CDD9F5" FontSize="11"/></StackPanel></Border><Button x:Name="RefreshButton" Content="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="14" Width="30" MinHeight="30" Height="30" Padding="0" Margin="6,0,0,0" ToolTip="重新偵測螢幕" AutomationProperties.Name="重新偵測螢幕"/></StackPanel>
    </Grid>
    <Border Style="{StaticResource Glass}" Margin="0,0,0,8"><StackPanel>
     <Grid Margin="0,0,0,10"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="輸入來源" Foreground="{StaticResource Muted}" FontSize="11" VerticalAlignment="Center"/><TextBlock x:Name="CurrentInput" Grid.Column="1" Text="讀取中…" FontSize="13" FontWeight="SemiBold"/></Grid>
     <UniformGrid Columns="4" Margin="0,0,-8,0">
      <Button x:Name="DPButton" Tag="DP" Height="48" Margin="0,0,8,0" Padding="4" ToolTip="切換至 DisplayPort"><StackPanel><TextBlock Text="DP" FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock x:Name="DPShortcut" Text="Ctrl+Alt+0" FontSize="9" Foreground="#ADBBD7" HorizontalAlignment="Center" Margin="0,5,0,0"/><TextBlock x:Name="DPPortState" Visibility="Collapsed"/></StackPanel></Button>
      <Button x:Name="HDMI1Button" Tag="HDMI1" Height="48" Margin="0,0,8,0" Padding="4" ToolTip="切換至 HDMI 1；外部設備的接線狀態未知。"><StackPanel><TextBlock Text="HDMI 1" FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock x:Name="HDMI1Shortcut" Text="Ctrl+Alt+1" FontSize="9" Foreground="#ADBBD7" HorizontalAlignment="Center" Margin="0,5,0,0"/><TextBlock x:Name="HDMI1PortState" Visibility="Collapsed"/></StackPanel></Button>
      <Button x:Name="HDMI2Button" Tag="HDMI2" Height="48" Margin="0,0,8,0" Padding="4" ToolTip="切換至 HDMI 2；外部設備的接線狀態未知。"><StackPanel><TextBlock Text="HDMI 2" FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock x:Name="HDMI2Shortcut" Text="Ctrl+Alt+2" FontSize="9" Foreground="#ADBBD7" HorizontalAlignment="Center" Margin="0,5,0,0"/><TextBlock x:Name="HDMI2PortState" Visibility="Collapsed"/></StackPanel></Button>
      <Button x:Name="HDMI3Button" Tag="HDMI3" Height="48" Margin="0,0,8,0" Padding="4" ToolTip="切換至 HDMI 3；外部設備的接線狀態未知。"><StackPanel><TextBlock Text="HDMI 3" FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock x:Name="HDMI3Shortcut" Text="Ctrl+Alt+3" FontSize="9" Foreground="#ADBBD7" HorizontalAlignment="Center" Margin="0,5,0,0"/><TextBlock x:Name="HDMI3PortState" Visibility="Collapsed"/></StackPanel></Button>
     </UniformGrid>
    </StackPanel></Border>
    <Border Style="{StaticResource Glass}" Margin="0,0,0,10"><StackPanel>
     
     <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition/><ColumnDefinition Width="38"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="32"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="32"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="1"/><RowDefinition Height="10"/><RowDefinition Height="32"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <StackPanel VerticalAlignment="Center"><TextBlock Text="亮度"/></StackPanel><Slider x:Name="BrightnessSlider" Grid.Column="1" Minimum="0" Maximum="100" TickFrequency="1" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True" Margin="0,0,10,0" IsEnabled="False" AutomationProperties.Name="螢幕亮度百分比"/><TextBlock x:Name="BrightnessValue" Grid.Column="2" Text="—" Foreground="#CFD9F6" VerticalAlignment="Center"/><Button x:Name="BrightnessApply" Grid.Column="3" Tag="brightness" Content="套用" Padding="6,4" MinHeight="30" IsEnabled="False" AutomationProperties.Name="套用亮度"/>
      <TextBlock x:Name="BrightnessStatus" Grid.Row="1" Grid.ColumnSpan="4" Text="等待讀取亮度…" Foreground="#B3BFD9" FontSize="11" TextWrapping="Wrap" Margin="0,5,0,0"/>
      <StackPanel Grid.Row="3" VerticalAlignment="Center"><TextBlock Text="音量"/></StackPanel><Slider x:Name="VolumeSlider" Grid.Row="3" Grid.Column="1" Minimum="0" Maximum="100" TickFrequency="1" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True" Margin="0,0,10,0" IsEnabled="False" AutomationProperties.Name="螢幕喇叭音量百分比" ToolTip="調整螢幕喇叭音量"/><TextBlock x:Name="VolumeValue" Grid.Row="3" Grid.Column="2" Text="—" Foreground="#CFD9F6" VerticalAlignment="Center"/><Button x:Name="VolumeApply" Grid.Row="3" Grid.Column="3" Tag="volume" Content="套用" Padding="6,4" MinHeight="30" IsEnabled="False" AutomationProperties.Name="套用音量"/>
      <TextBlock x:Name="VolumeStatus" Grid.Row="4" Grid.ColumnSpan="4" Text="等待讀取音量…" Foreground="#B3BFD9" FontSize="11" TextWrapping="Wrap" Margin="0,5,0,0"/>
      <Border Grid.Row="6" Grid.ColumnSpan="4" Background="#12FFFFFF"/>
      <StackPanel Grid.Row="8" VerticalAlignment="Center"><TextBlock Text="模式"/></StackPanel><ComboBox x:Name="SmartImagePicker" Grid.Row="8" Grid.Column="1" Grid.ColumnSpan="2" IsEnabled="False" Margin="0,0,14,0" AutomationProperties.Name="SmartImage 模式"><ComboBoxItem Tag="0" Content="關閉 · Off"/><ComboBoxItem Tag="11" Content="低藍光 · LowBlue"/></ComboBox><Button x:Name="SmartImageApply" Grid.Row="8" Grid.Column="3" Content="套用" Padding="6,4" MinHeight="30" IsEnabled="False" AutomationProperties.Name="套用 SmartImage 模式"/>
      <TextBlock x:Name="SmartImageStatus" Grid.Row="9" Grid.ColumnSpan="4" Text="等待讀取影像模式…" Foreground="#B3BFD9" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"/>
     </Grid>
    </StackPanel></Border>
    <Border Background="#08FFFFFF" CornerRadius="10" Padding="10,7" Margin="0,0,0,6"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions><Ellipse Width="4" Height="4" Fill="#A7BAFF" VerticalAlignment="Top" Margin="0,7,0,0"/><TextBlock Grid.Column="1" x:Name="StatusText" Text="正在連線…" TextWrapping="Wrap" FontSize="12" Foreground="#B6C2DE"/></Grid></Border>
    <Expander x:Name="DetailsExpander" Header="設定與詳細資訊" FontSize="11">
     <StackPanel Margin="0,10,0,0">
      <Border Style="{StaticResource Glass}" Padding="16" Margin="0,0,0,10"><StackPanel><TextBlock Text="目標螢幕" Foreground="{StaticResource Muted}" Margin="0,0,0,8"/><ComboBox x:Name="MonitorPicker"/><TextBlock x:Name="ConnectionSummary" Text="讀取中…" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,12,0,0"/><TextBlock Text="外部設備的接線狀態無法偵測；目前來源不代表有訊號。" Foreground="{StaticResource Muted}" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/><TextBlock x:Name="ConnectionTimestamp" Foreground="{StaticResource Muted}" FontSize="11" Margin="0,6,0,0"/><TextBlock x:Name="LastRead" Foreground="{StaticResource Muted}" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/><TextBlock Text="若快捷鍵無法返回 DP，請用螢幕實體按鈕返回。" Foreground="#E3C99F" TextWrapping="Wrap" FontSize="11" Margin="0,10,0,0"/></StackPanel></Border>
      <Expander x:Name="SettingsExpander" Header="快捷鍵與進階設定"><StackPanel x:Name="SettingsPanel" Margin="0,12,0,14">
       <TextBlock Text="Ctrl／Alt／Shift + 字母、數字或 F1–F24；留白停用。來源代碼為十六進位。" Foreground="{StaticResource Muted}" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,12"/>
       <Grid x:Name="ShortcutGrid"><Grid.ColumnDefinitions><ColumnDefinition Width="65"/><ColumnDefinition Width="*"/><ColumnDefinition Width="48"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="44"/><RowDefinition Height="44"/><RowDefinition Height="44"/><RowDefinition Height="44"/></Grid.RowDefinitions>
        <TextBlock Text="來源"/><TextBlock Grid.Column="1" Text="快捷鍵"/><TextBlock Grid.Column="2" Text="代碼"/><TextBlock Grid.Column="3" Text="狀態"/>
        <TextBlock Grid.Row="1" Text="DisplayPort" VerticalAlignment="Center"/><TextBox x:Name="DPKey" Grid.Row="1" Grid.Column="1" Margin="0,3,6,3" AutomationProperties.Name="DisplayPort 快捷鍵"/><TextBox x:Name="DPCode" Grid.Row="1" Grid.Column="2" Margin="0,3,6,3" AutomationProperties.Name="DisplayPort 來源代碼"/><TextBlock x:Name="DPNote" Grid.Row="1" Grid.Column="3" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="11"/>
        <TextBlock Grid.Row="2" Text="HDMI 1" VerticalAlignment="Center"/><TextBox x:Name="HDMI1Key" Grid.Row="2" Grid.Column="1" Margin="0,3,6,3" AutomationProperties.Name="HDMI 1 快捷鍵"/><TextBox x:Name="HDMI1Code" Grid.Row="2" Grid.Column="2" Margin="0,3,6,3" AutomationProperties.Name="HDMI 1 來源代碼"/><TextBlock x:Name="HDMI1Note" Grid.Row="2" Grid.Column="3" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="11"/>
        <TextBlock Grid.Row="3" Text="HDMI 2" VerticalAlignment="Center"/><TextBox x:Name="HDMI2Key" Grid.Row="3" Grid.Column="1" Margin="0,3,6,3" AutomationProperties.Name="HDMI 2 快捷鍵"/><TextBox x:Name="HDMI2Code" Grid.Row="3" Grid.Column="2" Margin="0,3,6,3" AutomationProperties.Name="HDMI 2 來源代碼"/><TextBlock x:Name="HDMI2Note" Grid.Row="3" Grid.Column="3" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="11"/>
        <TextBlock Grid.Row="4" Text="HDMI 3" VerticalAlignment="Center"/><TextBox x:Name="HDMI3Key" Grid.Row="4" Grid.Column="1" Margin="0,3,6,3" AutomationProperties.Name="HDMI 3 快捷鍵"/><TextBox x:Name="HDMI3Code" Grid.Row="4" Grid.Column="2" Margin="0,3,6,3" AutomationProperties.Name="HDMI 3 來源代碼"/><TextBlock x:Name="HDMI3Note" Grid.Row="4" Grid.Column="3" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="11"/>
       </Grid><StackPanel Orientation="Horizontal" Margin="0,12,0,0"><Button x:Name="SaveButton" Content="儲存設定" Margin="0,0,8,0"/><Button x:Name="ResetButton" Content="還原預設" Margin="0,0,8,0"/><Button x:Name="MinimizeButton" Content="最小化"/></StackPanel><TextBlock x:Name="SettingsMessage" Text="變更後按「儲存設定」套用。" Foreground="{StaticResource Muted}" TextWrapping="Wrap" FontSize="11" Margin="0,10,0,0"/>
      </StackPanel></Expander>
      <Expander Header="操作紀錄"><TextBox x:Name="LogBox" IsReadOnly="True" Height="110" Margin="0,8,0,12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"/></Expander><TextBlock Text="Display Studio · Prototype 1.6" Foreground="#77839F" FontSize="10" Margin="0,12,0,4"/>
     </StackPanel>
    </Expander>
    <TextBlock x:Name="HotkeySummary" Text="" Foreground="#E3C99F" TextWrapping="Wrap" FontSize="11" Margin="0,8,0,0" Visibility="Collapsed"/>
   </StackPanel>
  </ScrollViewer>
 </Grid>
</Window>
'@
$reader=[Xml.XmlNodeReader]::new($xaml)
$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$iconPath=Join-Path $BaseDirectory 'assets\app.ico'
if([IO.File]::Exists($iconPath)) {
    try {
        $icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath,[UriKind]::Absolute),[Windows.Media.Imaging.BitmapCreateOptions]::None,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $script:Window.Icon=$icon
    } catch { Write-Log ('無法載入程式圖示：'+$_.Exception.Message) }
}
$script:Controls=@{}
foreach($name in @('ConnectionBadge','ConnectionSummary','ConnectionTimestamp','MonitorPicker','RefreshButton','CurrentInput','StatusText','LastRead','DetailsExpander','SettingsExpander','SettingsPanel','SaveButton','ResetButton','MinimizeButton','SettingsMessage','HotkeySummary','LogBox')) { $script:Controls[$name]=$script:Window.FindName($name) }
foreach($key in $script:Sources) { foreach($suffix in @('Button','Shortcut','Key','Code','Note','PortState')) { $script:Controls[$key+$suffix]=$script:Window.FindName($key+$suffix) } }
foreach($key in @('Brightness','Volume')) { foreach($suffix in @('Slider','Value','Status','Apply')) { $script:Controls[$key+$suffix]=$script:Window.FindName($key+$suffix) } }
foreach($name in @('SmartImagePicker','SmartImageApply','SmartImageStatus')) { $script:Controls[$name]=$script:Window.FindName($name) }
$script:Window.MaxHeight=[Windows.SystemParameters]::WorkArea.Height-24
$script:Window.Height=[Math]::Min(460,$script:Window.MaxHeight)

function Set-Status([string]$message,[string]$kind='normal') {
    $display=$message
    if($kind -eq 'ok') {
        if($message.StartsWith('已連線 ')) { $display='已連線，可以切換來源。' }
        elseif($message.StartsWith('螢幕已回報 ')) { $display='輸入來源已讀回確認。' }
        elseif($message.StartsWith('SmartImage 已讀回確認')) { $display='影像模式已套用並讀回確認。' }
    }
    $script:Controls.StatusText.Text=$display
    $script:Controls.StatusText.ToolTip=$message
    $script:Controls.StatusText.Foreground=if($kind -eq 'error') { '#F2B4AD' } elseif($kind -eq 'ok') { '#C5D6FF' } else { '#B6C2DE' }
    $line=[DateTime]::Now.ToString('HH:mm:ss')+'  '+$message
    $script:Controls.LogBox.AppendText($line+[Environment]::NewLine)
    if($script:Controls.LogBox.Text.Length -gt 12000) { $script:Controls.LogBox.Text=$script:Controls.LogBox.Text.Substring($script:Controls.LogBox.Text.Length-8000) }
    $script:Controls.LogBox.ScrollToEnd(); Write-Log $message
}
function Update-ControlHints {
    $lowBlue=($script:Levels -and $script:Levels.SmartImage -and $script:Levels.SmartImage.Available -and $script:Levels.SmartImage.Code -eq 11)
    foreach($key in @('Brightness','Volume')) {
        $hint=$script:Controls[$key+'Status']
        $hint.Visibility=if($hint.Text.StartsWith('螢幕讀回：') -or ($key -eq 'Brightness' -and $lowBlue)) { 'Collapsed' } else { 'Visible' }
        $script:Controls[$key+'Slider'].ToolTip=$hint.Text
    }
    $hint=$script:Controls.SmartImageStatus
    $hint.Visibility=if($hint.Text.StartsWith('目前螢幕回報：Off')) { 'Collapsed' } else { 'Visible' }
}
function Set-Busy([bool]$value) {
    $script:Busy=$value
    $script:Controls.RefreshButton.IsEnabled=-not $value
    $script:Controls.MonitorPicker.IsEnabled=-not $value
    $script:Controls.SaveButton.IsEnabled=-not $value
    foreach($key in $script:Sources) { $script:Controls[$key+'Button'].IsEnabled=(-not $value -and -not [string]::IsNullOrEmpty($script:Config.MonitorId)) }
    foreach($key in @('Brightness','Volume')) {
        $enabled=(-not $value -and $null -ne $script:Levels -and $null -ne $script:Levels.$key -and $script:Levels.$key.Available)
        if($key -eq 'Brightness' -and $script:Levels -and $script:Levels.SmartImage -and $script:Levels.SmartImage.Available -and $script:Levels.SmartImage.Code -eq 11) { $enabled=$false }
        $script:Controls[$key+'Slider'].IsEnabled=$enabled
        $script:Controls[$key+'Apply'].IsEnabled=$enabled
    }
    $script:Controls.SmartImagePicker.IsEnabled=(-not $value -and $null -ne $script:Levels -and $null -ne $script:Levels.SmartImage -and $script:Levels.SmartImage.Available)
    $script:Controls.SmartImageApply.IsEnabled=($script:Controls.SmartImagePicker.IsEnabled -and $null -ne $script:Controls.SmartImagePicker.SelectedItem)
}
function Fill-Settings($config) {
    foreach($key in $script:Sources) { $script:Controls[$key+'Key'].Text=$config.Hotkeys[$key]; $script:Controls[$key+'Code'].Text=('{0:X2}' -f $config.SourceValues[$key]) }
}
function Update-ShortcutLabels {
    $failures=0
    foreach($key in $script:Sources) {
        $note=$script:HotkeyNotes[$key]
        $script:Controls[$key+'Note'].Text=$note
        if($script:Registered.ContainsKey($key)) { $script:Controls[$key+'Shortcut'].Text=$script:Config.Hotkeys[$key] }
        elseif(-not $script:Config.Hotkeys[$key]) { $script:Controls[$key+'Shortcut'].Text='僅按鈕操作' }
        else { $script:Controls[$key+'Shortcut'].Text='快捷鍵未啟用'; $failures++ }
    }
    $script:Controls.HotkeySummary.Text=if($failures -gt 0) { "有 $failures 組快捷鍵未啟用，請展開設定查看並修改。" } else { '快捷鍵在程式開啟時有效，最小化後也能使用。' }
    $script:Controls.HotkeySummary.Visibility=if($failures -gt 0) { 'Visible' } else { 'Collapsed' }
}
function Register-ConfigKeys($config) {
    foreach($key in $script:Sources) {
        $index=[Array]::IndexOf($script:Sources,$key)
        $errorCode=[MonitorInputPrototype.Native]::Bind($script:Handle,(100+$index),$config.Hotkeys[$key])
        if(-not $config.Hotkeys[$key]) { $script:HotkeyNotes[$key]='已停用' }
        elseif($errorCode -eq 0) { $script:Registered[$key]=100+$index; $script:HotkeyNotes[$key]='已啟用' }
        else { $script:HotkeyNotes[$key]=if($errorCode -eq 1409) { '被其他程式占用 (1409)' } else { "註冊失敗 ($errorCode)" } }
    }
}
function Unregister-Keys {
    foreach($id in @($script:Registered.Values)) { [MonitorInputPrototype.Native]::Unbind($script:Handle,$id) }
    $script:Registered=@{}
}
function Start-Operation([string]$operation,[string]$sourceKey='',[int]$levelValue=-1) {
    if($script:Busy -or $script:Closed) { return }
    if($operation -ne 'discover' -and -not $script:Config.MonitorId) { Set-Status '找不到已選定的飛利浦螢幕，請先重新偵測。' 'error'; return }
    $script:Pending=$operation; $script:PendingSource=$sourceKey; $script:Started=[DateTime]::UtcNow; $script:SlowNotice=$false
    $requested=if($operation -in @('brightness','volume','smartimage')) { $levelValue } elseif($sourceKey) { $script:Config.SourceValues[$sourceKey] } else { 0 }
    Set-Busy $true
    if($operation -eq 'switch') { Set-Status ('正在送出切換至 '+$script:Names[$sourceKey]+' 的指令…'); $script:Controls.LastRead.Text='切換中；下方來源值尚未重新確認。'; Show-Levels $null }
    elseif($operation -in @('brightness','volume')) { $name=if($operation -eq 'brightness') { '螢幕亮度' } else { '螢幕喇叭音量' }; Set-Status ('正在設定'+$name+'為 '+$levelValue+'%…') }
    elseif($operation -eq 'smartimage') { $name=if($levelValue -eq 11) { 'LowBlue' } else { 'Off' }; Set-Status ('正在將 SmartImage 設為 '+$name+'…') }
    elseif($operation -eq 'discover') { Set-Status '正在偵測螢幕與讀取 DDC/CI 狀態…' }
    $script:Task=[MonitorInputPrototype.Native]::Begin($operation,$script:Config.MonitorId,$requested)
}
function Show-Current([int]$value) {
    $script:Controls.CurrentInput.Text=Source-Name $value
    $script:Controls.LastRead.Text=if($value -ge 0) { ('最後讀取：{0} · VCP 0x60 = 0x{1:X2}' -f [DateTime]::Now.ToString('HH:mm:ss'),$value) } else { '目前來源無法確認；可嘗試返回 DP 或使用實體按鈕。' }
    foreach($key in $script:Sources) {
        $active=($script:Config.SourceValues[$key] -eq $value)
        $script:Controls[$key+'Button'].Background=if($active) { '#364E6BA8' } else { '#0AFFFFFF' }
        $script:Controls[$key+'Button'].BorderBrush=if($active) { '#8B9AC8FF' } else { '#22FFFFFF' }
    }
}
function Show-Levels($levels) {
    $script:Levels=$levels; $script:UpdatingLevels=$true
    try {
        $preset=if($levels) { $levels.SmartImage } else { $null }
        $lowBlue=($preset -and $preset.Available -and $preset.Code -eq 11)
        foreach($key in @('Brightness','Volume')) {
            $level=if($levels) { $levels.$key } else { $null }
            if($level -and $level.Available) {
                $script:Controls[$key+'Slider'].Value=$level.Percent
                $script:Controls[$key+'Value'].Text=([string]$level.Percent+'%')
                $script:Controls[$key+'Status'].Text=('螢幕讀回：{0}／{1} · {2}' -f $level.Current,$level.Maximum,[DateTime]::Now.ToString('HH:mm:ss'))
            } else {
                $script:Controls[$key+'Value'].Text='—'
                $detail=if($level) { ' 錯誤 0x'+$level.Error.ToString('X8') } else { '' }
                $script:Controls[$key+'Status'].Text='目前無法讀取；可能未開放控制、模式鎖定或 DDC 未回應。'+$detail
            }
            $script:Controls[$key+'Slider'].IsEnabled=(-not $script:Busy -and $null -ne $level -and $level.Available)
            if($key -eq 'Brightness' -and $lowBlue) {
                $script:Controls[$key+'Slider'].IsEnabled=$false
                $script:Controls[$key+'Status'].Text='LowBlue 可能覆蓋背光亮度；本工具暫停調亮度，切回 SmartImage Off 可恢復。'
            }
            $script:Controls[$key+'Apply'].IsEnabled=$script:Controls[$key+'Slider'].IsEnabled
        }
        $script:Controls.SmartImagePicker.SelectedIndex=-1
        if($preset -and $preset.Available) {
            if($preset.Code -eq 0) { $script:Controls.SmartImagePicker.SelectedIndex=0; $script:Controls.SmartImageStatus.Text='目前螢幕回報：Off。可使用下方亮度控制。' }
            elseif($preset.Code -eq 11) { $script:Controls.SmartImagePicker.SelectedIndex=1; $script:Controls.SmartImageStatus.Text='LowBlue 已開啟；工具暫停亮度控制，切回 Off 可恢復。' }
            else { $script:Controls.SmartImageStatus.Text=('目前為其他 SmartImage 模式（0x{0:X2}）；可選擇 Off 或 LowBlue 後套用。' -f $preset.Code) }
        } else { $script:Controls.SmartImageStatus.Text='目前無法讀取 SmartImage；請重新偵測。' }
        $script:Controls.SmartImagePicker.IsEnabled=(-not $script:Busy -and $null -ne $preset -and $preset.Available)
        $script:Controls.SmartImageApply.IsEnabled=($script:Controls.SmartImagePicker.IsEnabled -and $null -ne $script:Controls.SmartImagePicker.SelectedItem)
    } finally { $script:UpdatingLevels=$false; Update-ControlHints }
}
function Show-Connections($result) {
    $snapshot=Get-ConnectionSnapshot $result $script:Config.MonitorId
    $script:Controls.ConnectionSummary.Text=$snapshot.Summary
    foreach($key in $script:Sources) {
        $script:Controls[$key+'PortState'].Text=$snapshot.Ports[$key]
        $script:Controls[$key+'PortState'].Foreground=if($snapshot.Ports[$key] -eq '本機已偵測') { '#8EE6C7' } else { '#AABCD1' }
    }
    $script:Controls.ConnectionTimestamp.Text='上次本機偵測：'+[DateTime]::Now.ToString('HH:mm:ss')+'；按「重新偵測」更新。'
}
function Complete-Operation($result) {
    if($script:Pending -eq 'discover' -and $result.State -eq 'discovered') {
        $script:MonitorRecords=@($result.Monitors | Where-Object IsPhilips)
        $script:Populating=$true
        $script:Controls.MonitorPicker.Items.Clear()
        foreach($monitor in $script:MonitorRecords) { [void]$script:Controls.MonitorPicker.Items.Add($monitor) }
        $selected=$null
        foreach($monitor in $script:MonitorRecords) { if($monitor.Id -eq $script:Config.MonitorId) { $selected=$monitor; break } }
        if(-not $selected -and -not $script:Config.MonitorId -and $script:MonitorRecords.Count -eq 1) { $selected=$script:MonitorRecords[0]; $script:Config.MonitorId=$selected.Id; try { Save-Config $script:Config } catch { Set-Status ('無法儲存螢幕設定：'+$_.Exception.Message) 'error' } }
        if($selected) {
            $script:Controls.MonitorPicker.SelectedItem=$selected
            $script:Controls.ConnectionBadge.Text=if($selected.Current -ge 0) { '已連線' } else { '未回應' }
            Show-Current $selected.Current
            Show-Levels $selected.Levels
            if($selected.Current -ge 0) { Set-Status ('已連線 '+$selected.Name+'，螢幕回報 '+(Source-Name $selected.Current)+'。') 'ok' }
            else { Set-Status ('已找到螢幕，但無法讀取 DDC/CI。可檢查螢幕 DDC/CI 設定、線材，或嘗試返回 DP。錯誤 0x'+$selected.ReadError.ToString('X8')) 'error' }
        } else {
            $script:Controls.ConnectionBadge.Text='未連線'; Show-Current -1; Show-Levels $null
            if($script:MonitorRecords.Count -gt 0) { Set-Status '已儲存的螢幕目前不在清單；請明確選擇目標，避免切到另一台螢幕。' 'error' }
            else { Set-Status '找不到可控制的 Philips 498P9Z。請確認本機仍與螢幕連線；必要時用實體按鈕返回 DP。' 'error' }
        }
        $script:LastConnectionResult=$result
        Show-Connections $result
        $script:Populating=$false
    } elseif($script:Pending -eq 'switch') {
        Show-Current $result.Current
        Show-Levels $result.Levels
        if($result.State -eq 'confirmed') { $script:Controls.ConnectionBadge.Text='已連線'; Set-Status ('螢幕已回報 '+(Source-Name $result.Current)+'。實際畫面與接孔對應請確認。') 'ok' }
        elseif($result.Sent) { $script:Controls.ConnectionBadge.Text='尚未確認'; $extra=if($result.Current -ge 0) { '螢幕仍回報 '+(Source-Name $result.Current)+'。' } else { 'DDC/CI 暫時無回應。' }; Set-Status ('指令已送出，尚未確認。'+$extra+' 若無法返回，請用螢幕實體按鈕切回 DP。') }
        else { $script:Controls.ConnectionBadge.Text='切換未完成'; Set-Status ('切換未完成；未取得指令成功送出的確認。'+$result.Message+' 錯誤 0x'+$result.Error.ToString('X8')+'；可用實體按鈕返回 DP。') 'error' }
    } elseif($script:Pending -eq 'smartimage') {
        Show-Levels $result.Levels
        $name=if($result.LevelRequested -eq 11) { 'LowBlue' } else { 'Off' }
        if($result.State -eq 'confirmed') { Set-Status ('SmartImage 已讀回確認為 '+$name+'；亮度與音量已重新讀取。') 'ok' }
        elseif($result.Sent) { Set-Status 'SmartImage 指令已送出，尚未確認；請查看螢幕選單。' }
        else { Set-Status ('SmartImage 設定未完成：'+$result.Message+' 錯誤 0x'+$result.Error.ToString('X8')) 'error' }
    } elseif($script:Pending -in @('brightness','volume')) {
        Show-Levels $result.Levels
        $name=if($script:Pending -eq 'brightness') { '螢幕亮度' } else { '螢幕喇叭音量' }
        if($result.State -eq 'confirmed') { Set-Status ($name+'已讀回確認為 '+$result.LevelRequested+'%。') 'ok' }
        elseif($result.State -eq 'modeblocked') { Set-Status 'LowBlue 可能覆蓋背光亮度；請先套用 SmartImage Off，再調整亮度。' }
        elseif($result.Sent) { Set-Status ($name+'指令已送出，尚未讀回確認；請查看螢幕實際反應。') }
        else { Set-Status ($name+'設定未完成：'+$result.Message+' 錯誤 0x'+$result.Error.ToString('X8')) 'error' }
    } elseif($result.State -eq 'read') { Show-Current $result.Current; Show-Levels $result.Levels; Set-Status ('螢幕回報 '+(Source-Name $result.Current)+'。') 'ok' }
    else { Show-Current -1; Show-Levels $result.Levels; if($script:Pending -eq 'discover') { Show-Connections $null }; Set-Status ('無法完成讀取：'+$result.Message) 'error' }
    if($script:ConfigWarning) { $script:Controls.SettingsMessage.Text=$script:ConfigWarning }
}
function Register-LevelEvents {
    $script:Controls.SmartImagePicker.Add_SelectionChanged({
        if($script:UpdatingLevels) { return }
        $script:Controls.SmartImageApply.IsEnabled=(-not $script:Busy -and $script:Levels -and $script:Levels.SmartImage -and $script:Levels.SmartImage.Available -and $null -ne $script:Controls.SmartImagePicker.SelectedItem)
        $script:Controls.SmartImageStatus.Text='尚未套用，按右側「套用」生效。'
        Update-ControlHints
    })
    $script:Controls.SmartImageApply.Add_Click({
        $selected=$script:Controls.SmartImagePicker.SelectedItem
        if($selected) { Start-Operation 'smartimage' '' ([int]$selected.Tag) }
    })
    foreach($key in @('Brightness','Volume')) {
        $script:Controls[$key+'Slider'].Tag=$key
        $script:Controls[$key+'Slider'].Add_ValueChanged({
            param($sender,$eventArgs)
            if($script:UpdatingLevels) { return }
            $controlKey=[string]$sender.Tag
            $script:Controls[$controlKey+'Value'].Text=([string][int]$sender.Value+'%')
            $script:Controls[$controlKey+'Status'].Text='尚未套用；按右側按鈕才會修改螢幕。'
            Update-ControlHints
        })
        $script:Controls[$key+'Apply'].Add_Click({
            param($sender,$eventArgs)
            $controlKey=if($sender.Tag -eq 'brightness') { 'Brightness' } else { 'Volume' }
            Start-Operation ([string]$sender.Tag) '' ([int]$script:Controls[$controlKey+'Slider'].Value)
        })
    }
}
$script:Controls.RefreshButton.Add_Click({ Start-Operation 'discover' })
foreach($key in $script:Sources) { $script:Controls[$key+'Button'].Add_Click({ param($sender,$eventArgs) Start-Operation 'switch' ([string]$sender.Tag) }) }
Register-LevelEvents
$script:Controls.MonitorPicker.Add_SelectionChanged({
    if($script:Populating -or $script:Busy) { return }
    $selected=$script:Controls.MonitorPicker.SelectedItem
    if($selected) { $script:Config.MonitorId=$selected.Id; Show-Connections $script:LastConnectionResult; try { Save-Config $script:Config; Start-Operation 'read' } catch { Set-Status ('無法儲存螢幕設定：'+$_.Exception.Message) 'error' } }
})
$script:Controls.ResetButton.Add_Click({ Fill-Settings (New-DefaultConfig); $script:Controls.SettingsMessage.Text='已填入預設值，按「儲存並套用」才會生效。' })
$script:Controls.MinimizeButton.Add_Click({ $script:Window.WindowState='Minimized' })
$script:Controls.SaveButton.Add_Click({
    $old=$script:Config
    try {
        $candidate=New-DefaultConfig; $candidate.MonitorId=$old.MonitorId
        foreach($key in $script:Sources) {
            $candidate.Hotkeys[$key]=[MonitorInputPrototype.Native]::ParseHotkey($script:Controls[$key+'Key'].Text).Text
            $hex=$script:Controls[$key+'Code'].Text.Trim() -replace '^0[xX]',''
            if($hex -notmatch '^[0-9a-fA-F]{1,2}$') { throw ($script:Names[$key]+' 的代碼需為 01–FF 的十六進位數值。') }
            $candidate.SourceValues[$key]=[Convert]::ToInt32($hex,16)
        }
        $candidate=Convert-Config ($candidate | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        Unregister-Keys; Register-ConfigKeys $candidate
        $conflicts=@($script:Sources | Where-Object { $candidate.Hotkeys[$_] -and -not $script:Registered.ContainsKey($_) })
        if($conflicts.Count -gt 0) {
            $details=($conflicts | ForEach-Object { $script:Names[$_]+': '+$script:HotkeyNotes[$_] }) -join '；'
            Unregister-Keys; Register-ConfigKeys $old; Update-ShortcutLabels
            throw ('快捷鍵未套用：'+$details+'。已嘗試恢復原快捷鍵，請修改後重試。')
        }
        try { Save-Config $candidate } catch { Unregister-Keys; Register-ConfigKeys $old; Update-ShortcutLabels; throw }
        $script:Config=$candidate; Fill-Settings $candidate; Update-ShortcutLabels
        $script:Controls.SettingsMessage.Text='設定已儲存並套用。'; Set-Status '已更新快捷鍵與來源代碼。'
        Start-Operation 'read'
    } catch { $script:Controls.SettingsMessage.Text=$_.Exception.Message; Write-Log ('設定未套用：'+$_.Exception.Message) }
})
$script:Timer=[Windows.Threading.DispatcherTimer]::new()
$script:Timer.Interval=[TimeSpan]::FromMilliseconds(120)
$script:Timer.Add_Tick({
    if(-not $script:Task) { return }
    if(-not $script:Task.IsCompleted) {
        if(-not $script:SlowNotice -and ([DateTime]::UtcNow-$script:Started).TotalSeconds -gt 10) { $script:SlowNotice=$true; Set-Status '顯示驅動仍在等待回應，尚未完成；視窗可以操作，暫停送出新指令。若長時間無回應，可關閉重開工具。' }
        return
    }
    try { $result=$script:Task.GetAwaiter().GetResult(); Complete-Operation $result }
    catch { Set-Status ('處理失敗：'+$_.Exception.Message) 'error' }
    finally { $script:Task=$null; Set-Busy $false }
})
$script:Window.Add_SourceInitialized({
    $script:Handle=[Windows.Interop.WindowInteropHelper]::new($script:Window).Handle
    [MonitorInputPrototype.Native]::StyleWindow($script:Handle)
    $script:HwndSource=[Windows.Interop.HwndSource]::FromHwnd($script:Handle)
    $script:Hook=[Windows.Interop.HwndSourceHook]{ param([IntPtr]$hwnd,[int]$msg,[IntPtr]$wParam,[IntPtr]$lParam,[ref]$handled)
        if($msg -eq 0x0312) {
            $handled.Value=$true
            $index=$wParam.ToInt32()-100
            if($index -ge 0 -and $index -lt 4 -and -not $script:Controls.SettingsPanel.IsKeyboardFocusWithin) { Start-Operation 'switch' $script:Sources[$index] }
        }
        return [IntPtr]::Zero
    }
    $script:HwndSource.AddHook($script:Hook)
    Register-ConfigKeys $script:Config; Update-ShortcutLabels
})
$script:Window.Add_ContentRendered({ if(-not $script:InitialDiscovery) { $script:InitialDiscovery=$true; $script:Timer.Start(); Start-Operation 'discover' } })
$script:Window.Add_Closed({ $script:Closed=$true; $script:Timer.Stop(); Unregister-Keys; if($script:HwndSource) { $script:HwndSource.RemoveHook($script:Hook) } })
Fill-Settings $script:Config; Set-Busy $false
try { [void]$script:Window.ShowDialog() }
finally { $script:Timer.Stop(); if($script:Handle) { Unregister-Keys }; $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() }
