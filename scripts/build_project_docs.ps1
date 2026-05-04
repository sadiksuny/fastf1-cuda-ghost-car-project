param(
    [string]$OutputDir = "docs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-CleanDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path | Out-Null
}

function Escape-XmlText {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function New-DocParagraph {
    param(
        [string]$Text,
        [string]$Style = ""
    )
    $escaped = Escape-XmlText $Text
    if ([string]::IsNullOrWhiteSpace($Style)) {
        return "<w:p><w:r><w:t xml:space=`"preserve`">$escaped</w:t></w:r></w:p>"
    }
    return "<w:p><w:pPr><w:pStyle w:val=`"$Style`"/></w:pPr><w:r><w:t xml:space=`"preserve`">$escaped</w:t></w:r></w:p>"
}

function New-DocxPackage {
    param(
        [string]$DestinationPath,
        [string[]]$Paragraphs
    )

    $root = Join-Path $env:TEMP ("ghostcar-docx-" + [guid]::NewGuid().ToString("N"))
    $relsDir = Join-Path $root "_rels"
    $docPropsDir = Join-Path $root "docProps"
    $wordDir = Join-Path $root "word"
    $wordRelsDir = Join-Path $wordDir "_rels"

    New-Item -ItemType Directory -Path $relsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $docPropsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $wordDir -Force | Out-Null
    New-Item -ItemType Directory -Path $wordRelsDir -Force | Out-Null

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
"@ | Set-Content -LiteralPath (Join-Path $root "[Content_Types].xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
"@ | Set-Content -LiteralPath (Join-Path $relsDir ".rels") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                   xmlns:dc="http://purl.org/dc/elements/1.1/"
                   xmlns:dcterms="http://purl.org/dc/terms/"
                   xmlns:dcmitype="http://purl.org/dc/dcmitype/"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>Fast F1 CUDA Ghost Car Project Report</dc:title>
  <dc:creator>OpenAI Codex</dc:creator>
  <cp:lastModifiedBy>OpenAI Codex</cp:lastModifiedBy>
</cp:coreProperties>
"@ | Set-Content -LiteralPath (Join-Path $docPropsDir "core.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
            xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>OpenAI Codex</Application>
</Properties>
"@ | Set-Content -LiteralPath (Join-Path $docPropsDir "app.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:qFormat/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/>
    <w:basedOn w:val="Normal"/>
    <w:qFormat/>
    <w:rPr><w:b/><w:sz w:val="32"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
    <w:basedOn w:val="Normal"/>
    <w:qFormat/>
    <w:rPr><w:b/><w:sz w:val="28"/></w:rPr>
  </w:style>
</w:styles>
"@ | Set-Content -LiteralPath (Join-Path $wordDir "styles.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
"@ | Set-Content -LiteralPath (Join-Path $wordRelsDir "document.xml.rels") -Encoding UTF8

    $body = ($Paragraphs -join "`n")
    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
            xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
            xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
            xmlns:v="urn:schemas-microsoft-com:vml"
            xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
            xmlns:w10="urn:schemas-microsoft-com:office:word"
            xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
            xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
            xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk"
            xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml"
            xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
            mc:Ignorable="w14 wp14">
  <w:body>
$body
    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>
"@ | Set-Content -LiteralPath (Join-Path $wordDir "document.xml") -Encoding UTF8

    $zipPath = [System.IO.Path]::ChangeExtension($DestinationPath, ".zip")
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Force }
    Compress-Archive -Path (Join-Path $root "*") -DestinationPath $zipPath -Force
    Move-Item -LiteralPath $zipPath -Destination $DestinationPath
    Remove-Item -LiteralPath $root -Recurse -Force
}

function New-SlideXml {
    param(
        [string]$Title,
        [string[]]$Lines
    )
    $escapedTitle = Escape-XmlText $Title
    $runs = @()
    foreach ($line in $Lines) {
        $runs += "<a:p><a:r><a:rPr lang=`"en-US`" sz=`"2200`"/><a:t>$(Escape-XmlText $line)</a:t></a:r></a:p>"
    }
    $body = $runs -join ""
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
       xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld>
    <p:spTree>
      <p:nvGrpSpPr>
        <p:cNvPr id="1" name=""/>
        <p:cNvGrpSpPr/>
        <p:nvPr/>
      </p:nvGrpSpPr>
      <p:grpSpPr>
        <a:xfrm>
          <a:off x="0" y="0"/>
          <a:ext cx="0" cy="0"/>
          <a:chOff x="0" y="0"/>
          <a:chExt cx="0" cy="0"/>
        </a:xfrm>
      </p:grpSpPr>
      <p:sp>
        <p:nvSpPr>
          <p:cNvPr id="2" name="Title 1"/>
          <p:cNvSpPr/>
          <p:nvPr/>
        </p:nvSpPr>
        <p:spPr>
          <a:xfrm>
            <a:off x="457200" y="228600"/>
            <a:ext cx="8229600" cy="914400"/>
          </a:xfrm>
          <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
          <a:noFill/>
          <a:ln><a:noFill/></a:ln>
        </p:spPr>
        <p:txBody>
          <a:bodyPr wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720"/>
          <a:lstStyle/>
          <a:p><a:r><a:rPr lang="en-US" sz="2800" b="1"/><a:t>$escapedTitle</a:t></a:r></a:p>
        </p:txBody>
      </p:sp>
      <p:sp>
        <p:nvSpPr>
          <p:cNvPr id="3" name="Content 2"/>
          <p:cNvSpPr/>
          <p:nvPr/>
        </p:nvSpPr>
        <p:spPr>
          <a:xfrm>
            <a:off x="685800" y="1371600"/>
            <a:ext cx="7772400" cy="4343400"/>
          </a:xfrm>
          <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
          <a:noFill/>
          <a:ln><a:noFill/></a:ln>
        </p:spPr>
        <p:txBody>
          <a:bodyPr wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720"/>
          <a:lstStyle/>
          $body
        </p:txBody>
      </p:sp>
    </p:spTree>
  </p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>
"@
}

function New-PptxPackage {
    param(
        [string]$DestinationPath,
        [object[]]$Slides
    )

    $root = Join-Path $env:TEMP ("ghostcar-pptx-" + [guid]::NewGuid().ToString("N"))
    $relsDir = Join-Path $root "_rels"
    $docPropsDir = Join-Path $root "docProps"
    $pptDir = Join-Path $root "ppt"
    $pptRelsDir = Join-Path $pptDir "_rels"
    $slidesDir = Join-Path $pptDir "slides"
    $slidesRelsDir = Join-Path $slidesDir "_rels"

    New-Item -ItemType Directory -Path $relsDir,$docPropsDir,$pptDir,$pptRelsDir,$slidesDir,$slidesRelsDir -Force | Out-Null

    $slideOverrideLines = @()
    for ($i = 1; $i -le $Slides.Count; $i++) {
        $slideOverrideLines += "  <Override PartName=`"/ppt/slides/slide$i.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.presentationml.slide+xml`"/>"
    }
    $slideOverrides = $slideOverrideLines -join "`n"

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
  <Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>
  <Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>
  <Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
$slideOverrides
</Types>
"@ | Set-Content -LiteralPath (Join-Path $root "[Content_Types].xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
"@ | Set-Content -LiteralPath (Join-Path $relsDir ".rels") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                   xmlns:dc="http://purl.org/dc/elements/1.1/"
                   xmlns:dcterms="http://purl.org/dc/terms/"
                   xmlns:dcmitype="http://purl.org/dc/dcmitype/"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>Fast F1 CUDA Ghost Car Presentation</dc:title>
  <dc:creator>OpenAI Codex</dc:creator>
</cp:coreProperties>
"@ | Set-Content -LiteralPath (Join-Path $docPropsDir "core.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
            xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>OpenAI Codex</Application>
  <Slides>$($Slides.Count)</Slides>
</Properties>
"@ | Set-Content -LiteralPath (Join-Path $docPropsDir "app.xml") -Encoding UTF8

    $slideIdLines = @()
    $slideRelLines = @()
    for ($i = 1; $i -le $Slides.Count; $i++) {
        $slideIdLines += "    <p:sldId id=`"$(256 + $i)`" r:id=`"rId$i`"/>"
        $slideRelLines += "  <Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide`" Target=`"slides/slide$i.xml`"/>"
    }
    $slideIds = $slideIdLines -join "`n"
    $slideRels = $slideRelLines -join "`n"

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:sldSz cx="9144000" cy="6858000"/>
  <p:notesSz cx="6858000" cy="9144000"/>
  <p:sldIdLst>
$slideIds
  </p:sldIdLst>
</p:presentation>
"@ | Set-Content -LiteralPath (Join-Path $pptDir "presentation.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
$slideRels
</Relationships>
"@ | Set-Content -LiteralPath (Join-Path $pptRelsDir "presentation.xml.rels") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentationPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>
"@ | Set-Content -LiteralPath (Join-Path $pptDir "presProps.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:viewPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
          xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:normalViewPr/>
</p:viewPr>
"@ | Set-Content -LiteralPath (Join-Path $pptDir "viewProps.xml") -Encoding UTF8

    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>
"@ | Set-Content -LiteralPath (Join-Path $pptDir "tableStyles.xml") -Encoding UTF8

    for ($i = 0; $i -lt $Slides.Count; $i++) {
        $slide = $Slides[$i]
        $slideXml = New-SlideXml -Title $slide.Title -Lines $slide.Lines
        $slidePath = Join-Path $slidesDir ("slide" + ($i + 1) + ".xml")
        $slideXml | Set-Content -LiteralPath $slidePath -Encoding UTF8
        @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
"@ | Set-Content -LiteralPath (Join-Path $slidesRelsDir ("slide" + ($i + 1) + ".xml.rels")) -Encoding UTF8
    }

    $zipPath = [System.IO.Path]::ChangeExtension($DestinationPath, ".zip")
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Force }
    Compress-Archive -Path (Join-Path $root "*") -DestinationPath $zipPath -Force
    Move-Item -LiteralPath $zipPath -Destination $DestinationPath
    Remove-Item -LiteralPath $root -Recurse -Force
}

function New-PowerPointDeck {
    param(
        [string]$DestinationPath,
        [object[]]$Slides
    )

    $powerPoint = $null
    $presentation = $null
    try {
        $powerPoint = New-Object -ComObject PowerPoint.Application
        $powerPoint.Visible = -1
        $presentation = $powerPoint.Presentations.Add()

        foreach ($slideData in $Slides) {
            $slide = $presentation.Slides.Add($presentation.Slides.Count + 1, 12)

            $titleBox = $slide.Shapes.AddTextbox(1, 36, 24, 620, 50)
            $titleRange = $titleBox.TextFrame.TextRange
            $titleRange.Text = $slideData.Title
            $titleRange.Font.Size = 28
            $titleRange.Font.Bold = -1

            $bodyBox = $slide.Shapes.AddTextbox(1, 54, 110, 620, 330)
            $bodyRange = $bodyBox.TextFrame.TextRange
            $bodyRange.Text = ($slideData.Lines -join "`r`n")
            $bodyRange.Font.Size = 20

            for ($i = 1; $i -le $slideData.Lines.Count; $i++) {
                $paragraph = $bodyRange.Paragraphs($i)
                $paragraph.ParagraphFormat.Bullet.Visible = -1
            }
        }

        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force
        }
        $presentation.SaveAs($DestinationPath)
    } finally {
        if ($presentation) { $presentation.Close() }
        if ($powerPoint) { $powerPoint.Quit() | Out-Null }
    }
}

$reportParagraphs = @(
    (New-DocParagraph -Text "Fast F1 CUDA Ghost Car Project Report" -Style "Title"),
    (New-DocParagraph -Text "1. Project overview" -Style "Heading1"),
    (New-DocParagraph -Text "This project is a CUDA and C++ application for comparing two Formula 1 laps and visualizing the difference as a ghost car replay. The application aligns telemetry from two laps on a common distance basis, computes a time delta curve on the GPU, renders replay frames with a CUDA-backed drawing path, and produces a lightweight local HTML viewer that plays the resulting frame sequence in a browser."),
    (New-DocParagraph -Text "The project supports two main ways of working. The first path is a direct two-file comparison mode in which two CSV files are supplied to the executable. The second path is a session-folder mode in which a full session is exported once from Fast-F1 and the native application lets the user select a reference driver, a comparison driver, and specific laps from within that folder."),
    (New-DocParagraph -Text "2. Objectives and motivation" -Style "Heading1"),
    (New-DocParagraph -Text "The main objective of the project is to provide a practical GPU-based workflow for lap comparison. Instead of relying on static charts alone, the application presents the comparison as a replay in which both cars are shown at the same elapsed time. This makes it easier to understand where one driver is ahead, where time is lost, and how the lap evolves from braking zone to braking zone."),
    (New-DocParagraph -Text "A secondary objective is to keep the project usable on a local development machine. Python is used only for one-time Fast-F1 data export. Once the data is exported, the core comparison, rendering, and visualization steps are handled by the native CUDA and C++ application."),
    (New-DocParagraph -Text "3. System architecture" -Style "Heading1"),
    (New-DocParagraph -Text "The codebase is organized around a small set of focused components. The telemetry loader reads CSV files into a TelemetryLap structure with position, time, speed, throttle, and brake channels. The lap processing module performs cumulative distance computation, GPU resampling, delta calculation, smoothing, and CUDA-based frame rendering. The renderer module converts GPU image buffers into a host-side RGB image and writes BMP files. The UI module generates replay frames and writes a local HTML viewer. The main program handles command-line behavior, session-folder discovery, driver selection, lap selection, and launch of the full processing pipeline."),
    (New-DocParagraph -Text "The build is defined in CMake and produces a lap_core library plus the f1_ghost_app executable. CUDA is a first-class language in the project, and the main compute-heavy path lives in src/lap_processing.cu."),
    (New-DocParagraph -Text "4. Data pipeline" -Style "Heading1"),
    (New-DocParagraph -Text "The data pipeline begins either with existing CSV files or with the helper script scripts/export_fastf1_laps.py. The exporter uses Fast-F1 session data and merges position telemetry with car telemetry so that the resulting CSV format matches the native loader. The script supports three export modes: fastest-accurate-non-box, all-accurate, and all-laps. In session export mode it also writes session_manifest.json, which stores the session name, export mode, lap numbers, lap times, and generated filenames."),
    (New-DocParagraph -Text "On the native side, src/main.cpp reads either two CSV paths or a session folder. In folder mode it parses the manifest, groups entries by driver, prints the available drivers and the number of laps per driver, identifies the fastest exported lap for each selected driver, and allows either a specific lap choice or a default fastest-lap choice with D."),
    (New-DocParagraph -Text "5. CUDA processing approach" -Style "Heading1"),
    (New-DocParagraph -Text "The GPU processing path starts by computing cumulative distance along each lap. A CUDA kernel computes segment lengths from successive position samples, and thrust::scan is then used to build cumulative distance arrays. With that distance basis in place, both laps are resampled to a common uniform distance grid. The resampling kernel interpolates x, y, t, speed, throttle, and brake values so both laps can be compared sample-for-sample."),
    (New-DocParagraph -Text "Once both laps are resampled, a delta kernel computes compare time minus reference time across the common grid. The resulting delta curve is the quantitative foundation for the visual replay. Because both laps are aligned to the same distance grid, the delta is stable and consistent for track-based visualization."),
    (New-DocParagraph -Text "6. Rendering and visualization" -Style "Heading1"),
    (New-DocParagraph -Text "The rendering path is designed so the viewer reflects ahead-versus-behind status in a physically meaningful way. At each animation frame, the renderer samples both laps at the same elapsed time, not at the same distance index. This ensures that if one driver is ahead at that moment, the corresponding marker is also further along the lap visually."),
    (New-DocParagraph -Text "The CUDA frame renderer draws the base track, applies delta-based color mapping, and composites the key overlay elements such as the driver markers, legend, and lead banner. The renderer module then converts the returned RGB byte buffer to a host-side image representation and writes BMP files. The UI module generates 300 frames at a 100 millisecond playback interval and writes output/viewer.html, which uses a simple browser-based frame player with pause and resume controls."),
    (New-DocParagraph -Text "The viewer currently displays the reference and compare driver labels, the session label, the selected lap number and lap time for each driver, and the frame count. Session codes are expanded into readable names such as Race, Qualifying, and Free Practice 1."),
    (New-DocParagraph -Text "7. User interaction model" -Style "Heading1"),
    (New-DocParagraph -Text "The project now supports both quick and detailed comparison flows. A user can compare two supplied CSV files directly, or export an entire session and perform comparisons interactively from the session folder. In the interactive path, the user selects the drivers first and then either accepts the default fastest exported lap or chooses exact laps. This design keeps the default path simple while still supporting deeper analysis when needed."),
    (New-DocParagraph -Text "Terminal output has been intentionally reduced to the essentials. After selection, the program prints a loaded telemetry line and a final output line when the frames and viewer have been written. This keeps the workflow clean for demo use."),
    (New-DocParagraph -Text "8. Strengths of the current implementation" -Style "Heading1"),
    (New-DocParagraph -Text "The project has several practical strengths. It keeps CUDA in the critical path where parallelism matters most. It provides a repeatable session export mechanism through Fast-F1. It supports both quick comparisons and exploratory lap-level comparisons. It also uses a plain HTML viewer, which avoids introducing a heavier runtime dependency or complex GUI layer."),
    (New-DocParagraph -Text "Another strength is the way the lap metadata is now carried through the system. The export script writes lap numbers and lap times, the native app preserves those values, and the viewer exposes them directly. This makes the replay easier to interpret and reduces ambiguity about which laps are being shown."),
    (New-DocParagraph -Text "9. Limitations and future work" -Style "Heading1"),
    (New-DocParagraph -Text "The current implementation still has clear extension points. The viewer is a frame-sequence player rather than a real-time interactive renderer. The HTML page is intentionally simple and does not yet support scrubbing, zooming, or telemetry graphs. The project also depends on local Fast-F1 export for official telemetry acquisition rather than performing native data retrieval in C++."),
    (New-DocParagraph -Text "Potential future work includes richer HTML controls, corner-by-corner analytics, per-sector summaries, better session parsing without regex-based manifest reads, additional export metadata such as tire compound or stint context, and more formal test coverage for the session-folder and manifest logic."),
    (New-DocParagraph -Text "10. Conclusion" -Style "Heading1"),
    (New-DocParagraph -Text "The project now functions as a focused CUDA-based ghost car comparison tool that can scale from two manually supplied laps to a full-session multi-lap workflow. It combines practical GPU processing, structured export metadata, and a simple browser-based replay surface. The result is a compact but capable system for visual lap comparison, with a clean path for future refinement in both the analysis and presentation layers.")
)

$slides = @(
    @{ Title = "Fast F1 CUDA Ghost Car"; Lines = @("CUDA/C++ lap comparison and ghost-car replay", "Fast-F1 export for real telemetry", "Native replay with browser viewer") },
    @{ Title = "Project Goal"; Lines = @("Compare two laps on a shared distance basis", "Show who is ahead at the same elapsed time", "Make replay easier to read than static delta tables") },
    @{ Title = "Architecture"; Lines = @("telemetry_loader: CSV import and sample data", "lap_processing.cu: distance, resampling, delta, GPU rendering", "renderer/ui/main: image output, viewer, session picker") },
    @{ Title = "Data Workflow"; Lines = @("Python export is one-time per session", "Session folders support fastest, all-accurate, and all-laps modes", "Manifest carries session, lap number, lap time, and filenames") },
    @{ Title = "CUDA Work"; Lines = @("Segment length kernel and cumulative distance scan", "Uniform distance-grid resampling for both laps", "Delta computation and frame rendering on the GPU") },
    @{ Title = "User Experience"; Lines = @("Folder picker supports driver and lap selection", "Default fastest exported lap is available with D", "Viewer shows session, drivers, lap numbers, lap times, and 300-frame replay") },
    @{ Title = "Current Limitations"; Lines = @("HTML viewer is intentionally simple", "No telemetry charts or interactive scrubbing yet", "Manifest parsing in C++ is lightweight rather than schema-driven") },
    @{ Title = "Next Steps"; Lines = @("Improve viewer controls and analytics", "Add richer session metadata", "Expand testing and robustness around exports and manifests") }
)

$outputRoot = Join-Path (Get-Location) $OutputDir
New-CleanDirectory -Path $outputRoot

$docxPath = Join-Path $outputRoot "fastf1_cuda_ghost_car_project_report.docx"
$pptxPath = Join-Path $outputRoot "fastf1_cuda_ghost_car_presentation.pptx"

New-DocxPackage -DestinationPath $docxPath -Paragraphs $reportParagraphs
New-PowerPointDeck -DestinationPath $pptxPath -Slides $slides

Write-Output "Wrote $docxPath"
Write-Output "Wrote $pptxPath"
