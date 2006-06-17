--
-- Module      : Page
-- Copyright   : (c) Conrad Parker 2006
-- License     : BSD-style
-- Maintainer  : conradp@cse.unsw.edu.au
-- Stability   : experimental
-- Portability : portable

module Ogg.Page (
  OggPage (..),
  pageScan,
  pageWrite,
  pageLength
) where

import Ogg.CRC
import Ogg.Utils
import Ogg.Granulepos

import Data.Word (Word8, Word32)
import Data.Bits

import Text.Printf

------------------------------------------------------------
-- Data
--

data OggPage =
  OggPage {
    pageOffset :: Int,
    pageContinued :: Bool,
    pageBOS :: Bool,
    pageEOS :: Bool,
    pageGranulepos :: Granulepos,
    pageSerialno :: Word32,
    pageSeqno :: Word32,
    pageSegments :: [[Word8]]
  }

------------------------------------------------------------
-- The Ogg page format
-- from RFC3533: http://www.ietf.org/rfc/rfc3533.txt
{-

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1| Byte
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| capture_pattern: Magic number for page start "OggS"           | 0-3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| version       | header_type   | granule_position              | 4-7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               | 8-11
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                               | bitstream_serial_number       | 12-15
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                               | page_sequence_number          | 16-19
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                               | CRC_checksum                  | 20-23
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                               |page_segments  | segment_table | 24-27
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| ...                                                           | 28-
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

-}

------------------------------------------------------------
-- OggPage functions
--

pageMarker :: [Word8]
pageMarker = [0x4f, 0x67, 0x67, 0x53] -- "OggS"

-- | Ogg version supported by this library
pageVersion :: Word8
pageVersion = 0x00

-- | Determine the length of a page that would be written
pageLength :: OggPage -> Int
pageLength (OggPage _ _ _ _ _ _ _ s) = 27 + numsegs + sum (map length s)
    where (numsegs, _) = buildSegtab 0 [] s

------------------------------------------------------------
-- pageWrite
--

-- | Construct a binary representation of an Ogg page
pageWrite :: OggPage -> [Word8]
pageWrite (OggPage _ cont bos eos gp serialno seqno s) = newPageData
  where
    newPageData = hData ++ crc ++ sData ++ body
    crcPageData = hData ++ zeroCRC ++ sData ++ body
    hData = pageMarker ++ version ++ htype ++ gp_ ++ ser_ ++ seqno_
    sData = segs

    version = fillField pageVersion 1
    htype = [headerType]
    gp_ = fillField (gpUnpack gp) 8
    ser_ = fillField serialno 4
    seqno_ = fillField seqno 4
    crc = fillField (genCRC crcPageData) 4
 
    headerType :: Word8
    headerType = c .|. b .|. e
    c = if cont then (bit 0 :: Word8) else 0
    b = if bos then (bit 1 :: Word8) else 0
    e = if eos then (bit 2 :: Word8) else 0

    -- Segment table
    segs = (toTwosComp (numsegs)) ++ segtab
    (numsegs, segtab) = buildSegtab 0 [] s

    -- Body data
    body = concat s

fillField :: Integral a => a -> Int -> [Word8]
fillField x n
  | l < n	= reverse ((take (n-l) $ repeat 0x00) ++ i)
  | l > n	= reverse (drop (l-n) i)
  | otherwise	= reverse i
                  where l = length i
                        i = toTwosComp x

buildSegtab :: Int -> [Word8] -> [[Word8]] -> (Int, [Word8])
buildSegtab numsegs accum [] = (numsegs, accum)
buildSegtab numsegs accum (x:xs) = buildSegtab (numsegs+length(tab)) (accum ++ tab) xs where
  (q,r) = quotRem (length x) 255
  tab = buildTab q r xs

buildTab :: Int -> Int -> [a] -> [Word8]
buildTab 0 r _ = [fromIntegral r]
-- don't add [0] if the last seg is cont
buildTab q 0 [] = take q $ repeat (255 :: Word8)
buildTab q r _ = ((take q $ repeat (255 :: Word8)) ++ [fromIntegral r])

------------------------------------------------------------
-- pageScan
--

-- | Read a list of data bytes into Ogg pages
pageScan :: [Word8] -> [OggPage]
pageScan = _pageScan 0 []

_pageScan :: Int -> [OggPage] -> [Word8] -> [OggPage]
_pageScan _ l [] = l
_pageScan o l r@(r1:r2:r3:r4:_)
    | [r1,r2,r3,r4] == pageMarker = _pageScan (o+pageLen) (l++[newpage]) rest
    | otherwise	= _pageScan (o+1) l (tail r)
      where (newpage, pageLen, rest) = pageBuild o r
_pageScan _ l _ = l -- length r < 4

pageBuild :: Int -> [Word8] -> (OggPage, Int, [Word8])
pageBuild o d = (newpage, pageLen, rest) where
  newpage = OggPage o cont bos eos gp serialno seqno segments
  htype = if (length d) > 5 then d !! 5 else 0
  cont = testBit htype 0
  bos = testBit htype 1
  eos = testBit htype 2
  gp = Granulepos (Just (fromTwosComp $ ixSeq 6 8 d))
  serialno = fromTwosComp $ ixSeq 14 4 d
  seqno = fromTwosComp $ ixSeq 18 4 d
  -- crc = fromTwosComp $ ixSeq 22 4 d
  numseg = fromTwosComp $ ixSeq 26 1 d
  st = take numseg (drop 27 d)
  segtab = map fromIntegral st
  headerSize = 27 + numseg
  bodySize = sum segtab
  body = take bodySize (drop headerSize d)
  segments = splitSegments [] 0 segtab body
  pageLen = headerSize + bodySize
  rest = drop pageLen d 

ixSeq :: Int -> Int -> [Word8] -> [Word8]
ixSeq off len s = reverse (take len (drop off s))

-- splitSegments segments accum segtab body
splitSegments :: [[Word8]] -> Int -> [Int] -> [Word8] -> [[Word8]]
splitSegments segments _ _ [] = segments
splitSegments segments 0 [] _ = segments
splitSegments segments accum [] body = segments++[take accum body]
splitSegments segments 0 (0:ls) body = splitSegments (segments++[]) 0 ls body
splitSegments segments accum (l:ls) body 
  | l == 255	= splitSegments segments (accum+255) ls body
  | otherwise	= splitSegments (segments++[newseg]) 0 ls newbody
                  where (newseg, newbody) = splitAt (accum+l) body

------------------------------------------------------------
-- Show
--

instance Show OggPage where
  show p@(OggPage o cont bos eos gp serialno seqno segment_table) =
    (printf "%07x" o) ++ ": serialno " ++ show serialno ++ ", granulepos " ++ show gp ++ flags ++ ": " ++ show (pageLength p) ++ " bytes\n" ++ "\t" ++ show (map length segment_table) ++ "\n"
    where flags = ifc ++ ifb ++ ife
          ifc = if cont then " (cont)" else ""
          ifb = if bos then " *** bos" else ""
          ife = if eos then " *** eos" else ""