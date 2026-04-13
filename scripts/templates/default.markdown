$if(titleblock)$$titleblock$

$else$$if(title)$---
title: $title$
$if(subtitle)$subtitle: $subtitle$
$endif$$if(author)$author:
$for(author)$- $author$
$endfor$$endif$$if(date)$date: $date$
$endif$---

$endif$$endif$$body$
