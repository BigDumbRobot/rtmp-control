<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html" encoding="utf-8"/>

<xsl:template match="/">
<html>
<head>
  <meta charset="utf-8"/>
  <meta http-equiv="refresh" content="5"/>
  <title>RTMP Server Status</title>
  <style>
    :root { --bg:#f6f6f4; --card:#fff; --fg:#1d1d1b; --muted:#6b6b66; --line:#e2e2dc; --live:#1f8a4c; --idle:#9a9a92; --warn:#b3261e; }
    @media (prefers-color-scheme: dark) { :root { --bg:#161615; --card:#21211f; --fg:#ececea; --muted:#a3a39c; --line:#33332f; --live:#4cc283; --idle:#77776f; --warn:#f2867d; } }
    body { margin:0; padding:24px 16px; background:var(--bg); color:var(--fg); font:15px/1.45 -apple-system, system-ui, sans-serif; }
    main { max-width:1000px; margin:0 auto; }
    h1 { font-size:20px; margin:0 0 4px; }
    .sub { color:var(--muted); margin:0 0 20px; font-size:13px; }
    .wrap { overflow-x:auto; background:var(--card); border:1px solid var(--line); border-radius:10px; }
    table { width:100%; border-collapse:collapse; }
    th, td { text-align:left; padding:10px 12px; border-bottom:1px solid var(--line); white-space:nowrap; }
    th { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); font-weight:600; }
    tr:last-child td { border-bottom:none; }
    .dot { display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:6px; vertical-align:middle; }
    .live .dot { background:var(--live); } .idle .dot { background:var(--idle); }
    .live { color:var(--live); font-weight:600; } .idle { color:var(--muted); }
    .num { font-variant-numeric:tabular-nums; }
    .muted { color:var(--muted); }
    a.kick { color:var(--warn); text-decoration:none; border:1px solid var(--warn); border-radius:6px; padding:3px 9px; font-size:13px; }
    .empty { padding:24px; color:var(--muted); text-align:center; }
  </style>
</head>
<body><main>
  <h1>RTMP Server Status</h1>
  <p class="sub">
    Up <xsl:call-template name="dur"><xsl:with-param name="ms" select="/rtmp/uptime * 1000"/></xsl:call-template>
    · Total in <span class="num"><xsl:value-of select="format-number(/rtmp/bw_in div 1000000, '0.00')"/></span> Mbps
    · Total out <span class="num"><xsl:value-of select="format-number(/rtmp/bw_out div 1000000, '0.00')"/></span> Mbps
    · Refreshes every 5 s
  </p>
  <div class="wrap">
    <xsl:choose>
      <xsl:when test="//live/stream">
        <table>
          <tr><th>Stream key</th><th>Status</th><th>From</th><th>Encoder</th><th>Video</th><th>Bitrate in</th><th>Live for</th><th>Viewers</th><th></th></tr>
          <xsl:for-each select="//application[name='live']/live/stream">
            <xsl:variable name="pub" select="client[publishing]"/>
            <tr>
              <td><strong><xsl:value-of select="name"/></strong></td>
              <td>
                <xsl:choose>
                  <xsl:when test="$pub"><span class="live"><span class="dot"/>Live</span></xsl:when>
                  <xsl:otherwise><span class="idle"><span class="dot"/>No source</span></xsl:otherwise>
                </xsl:choose>
              </td>
              <td class="muted"><xsl:value-of select="$pub/address"/></td>
              <td class="muted"><xsl:value-of select="$pub/flashver"/></td>
              <td class="num">
                <xsl:if test="meta/video/width">
                  <xsl:value-of select="meta/video/width"/>×<xsl:value-of select="meta/video/height"/>
                  <xsl:if test="meta/video/frame_rate"> @ <xsl:value-of select="round(meta/video/frame_rate)"/></xsl:if>
                </xsl:if>
              </td>
              <td class="num"><xsl:value-of select="format-number(bw_in div 1000000, '0.00')"/> Mbps</td>
              <td class="num"><xsl:call-template name="dur"><xsl:with-param name="ms" select="time"/></xsl:call-template></td>
              <td class="num"><xsl:value-of select="count(client[not(publishing)])"/></td>
              <td>
                <xsl:if test="$pub">
                  <a class="kick" href="/control/drop/publisher?app=live&amp;name={name}" onclick="return confirm('Disconnect the source on this key?')">Kick</a>
                </xsl:if>
              </td>
            </tr>
          </xsl:for-each>
        </table>
      </xsl:when>
      <xsl:otherwise><div class="empty">No streams right now.</div></xsl:otherwise>
    </xsl:choose>
  </div>
</main></body>
</html>
</xsl:template>

<xsl:template name="dur">
  <xsl:param name="ms"/>
  <xsl:variable name="s" select="floor($ms div 1000)"/>
  <xsl:variable name="h" select="floor($s div 3600)"/>
  <xsl:variable name="m" select="floor(($s mod 3600) div 60)"/>
  <xsl:if test="$h &gt; 0"><xsl:value-of select="$h"/>h </xsl:if>
  <xsl:value-of select="$m"/>m <xsl:value-of select="$s mod 60"/>s
</xsl:template>

</xsl:stylesheet>
