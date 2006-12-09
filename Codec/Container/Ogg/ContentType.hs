--
-- Module      : ContentType
-- Copyright   : (c) Conrad Parker 2006
-- License     : BSD-style
-- Maintainer  : conradp@cse.unsw.edu.au
-- Stability   : experimental
-- Portability : portable

module Codec.Container.Ogg.ContentType (
  ContentType (..),
  identify,
  granulerate,
  granuleshift,
  parseType,

  -- Some guaranteed-known content-types
  skeleton
) where

import Data.Bits
import qualified Data.ByteString.Lazy as L
import Data.Char
import Data.Map (fromList)
import Data.Maybe
import Data.Ratio

import Text.Printf

import Codec.Container.Ogg.ByteFields
import Codec.Container.Ogg.Granulerate
import Codec.Container.Ogg.MessageHeaders
import Codec.Container.Ogg.Timestamp
import Codec.Container.Ogg.TimeScheme

------------------------------------------------------------
-- Data
--

data ContentType =
  ContentType {
    label :: String,
    mime :: [String],
    identifyP :: L.ByteString -> Bool, -- predictate, used by identify
    headers :: Int,
    preroll :: Int,
    granulerateF :: Maybe (L.ByteString -> Granulerate), -- used by granulerate
    granuleshiftF :: Maybe (L.ByteString -> Int), -- used by granuleshift
    metadata :: L.ByteString -> MessageHeaders
  }

known :: [ContentType]
known = [skeleton, cmml, vorbis, theora, speex, flac, oggpcm2]

identify :: L.ByteString -> Maybe ContentType
identify d = listToMaybe $ filter (\x -> identifyP x d) known

granulerate :: ContentType -> L.ByteString -> Maybe Granulerate
granulerate c d = maybe Nothing (\f -> Just (f d)) (granulerateF c)

granuleshift :: ContentType -> L.ByteString -> Maybe Int
granuleshift c d = maybe Nothing (\f -> Just (f d)) (granuleshiftF c)

parseType :: Maybe String -> Maybe ContentType
parseType Nothing = Nothing
parseType (Just s) = listToMaybe $ filter (\x ->  l (label x) == l s) known
  where
    l = map toLower

instance Eq ContentType where
  (==) a b = label a == label b

instance Show ContentType where
  show x = label x

------------------------------------------------------------
-- Skeleton
--

skeleton :: ContentType
skeleton = ContentType
             "Skeleton"                     -- label
             ["application/x-ogg-skeleton"] -- mime
             (L.isPrefixOf skeletonIdent)   -- identify
             0                              -- headers
             0                              -- preroll
             Nothing                        -- granulerate
             Nothing                        -- granuleshift
             skeletonMetadata

-- skeletonIdent = 'fishead\0'
skeletonIdent :: L.ByteString
skeletonIdent = L.pack [0x66, 0x69, 0x73, 0x68, 0x65, 0x61, 0x64, 0x00]

-- Extract the Presentation time, Basetime from Fishead (Skeleton BOS)
skeletonMetadata :: L.ByteString -> MessageHeaders
skeletonMetadata d = MessageHeaders (fromList headerVals)
  where headerVals = [prestime, basetime]
        prestime = ("Presentation-Time", [show p])
        basetime = ("Basetime", [show b])
        p = Timestamp (Just (le64At 12 d, le64At 20 d))
        b = Timestamp (Just (le64At 28 d, le64At 36 d))

------------------------------------------------------------
-- CMML
--

cmml :: ContentType
cmml = ContentType
         "CMML"                   -- label
         ["text/x-cmml"]          -- mime
         (L.isPrefixOf cmmlIdent) -- identify
         3                        -- headers
         0                        -- preroll
         (Just (\d -> fracRate (le64At 12 d) (le64At 20 d))) -- granulerate
         (Just (\d -> u8At 28 d)) -- granuleshift
             (const mhEmpty)

-- cmmlIdent = 'CMML\0\0\0\0\'
cmmlIdent :: L.ByteString
cmmlIdent = L.pack [0x43, 0x4d, 0x4d, 0x4c, 0x00, 0x00, 0x00, 0x00]

------------------------------------------------------------
-- Vorbis
--

vorbis :: ContentType
vorbis = ContentType
           "Vorbis"                   -- label
           ["audio/x-vorbis"]         -- mime
           (L.isPrefixOf vorbisIdent) -- identify
           3                          -- headers
           2                          -- preroll
           (Just (\d -> intRate (le32At 12 d))) -- granulerate
           Nothing                    -- granuleshift
           vorbisMetadata

-- vorbisIdent = '\x01vorbis'
vorbisIdent :: L.ByteString
vorbisIdent = L.pack [0x01, 0x76, 0x6f, 0x72, 0x62, 0x69, 0x73]

-- Extract sample rate from Vorbis BOS header
vorbisMetadata :: L.ByteString -> MessageHeaders
vorbisMetadata d = MessageHeaders (fromList headerVals)
  where headerVals = [samplerate, channels]
        samplerate = ("Audio-Samplerate", [printf "%d Hz" srate])
        channels = ("Audio-Channels", [show c])
        srate = (le32At 12 d) :: Int
        c = (u8At 11 d) :: Int

------------------------------------------------------------
-- Theora
--

theora :: ContentType
theora = ContentType
           "Theora"                   -- label
           ["video/x-theora"]         -- mime
           (L.isPrefixOf theoraIdent) -- identify
           3                          -- headers
           0                          -- preroll
           (Just (\d -> fracRate (be32At 22 d) (be32At 26 d))) -- granulerate
           (Just theoraGranuleshift)  -- granuleshift
           theoraMetadata             -- metadata

-- theoraIdent = '\x80theora'
theoraIdent :: L.ByteString
theoraIdent = L.pack [0x80, 0x74, 0x68, 0x65, 0x6f, 0x72, 0x61]

-- Theora's granuleshift is an 8 bit field split over two bytes
theoraGranuleshift :: L.ByteString -> Int
theoraGranuleshift d = (h40 .|. h41)
  where h40 = (u8At 40 d .&. 0x03) `shiftL` 3
        h41 = (u8At 41 d .&. 0xe0) `shiftR` 5

-- Extract video dimensions etc. from the Theora BOS header
theoraMetadata :: L.ByteString -> MessageHeaders
theoraMetadata d = MessageHeaders (fromList headerVals)
  where headerVals = [framerate, width, height]
        framerate = ("Video-Framerate", [printf "%.3f fps%s" fps tsName])
        width = ("Video-Width", [show w])
        height = ("Video-Height", [show h])
        toDouble :: Integer -> Double -- monomorphic cast to double
        toDouble x = (fromIntegral x) :: Double
        fps = toDouble fpsN / toDouble fpsD
        mTS = guessTimeScheme (fpsN % fpsD)
        tsName = maybe "" (\x -> " (" ++ show x ++ ")") mTS
        fpsN = be32At 22 d
        fpsD = be32At 26 d
        w = ((be16At 10 d) * 16) :: Int
        h = ((be16At 12 d) * 16) :: Int

------------------------------------------------------------
-- Speex
--

speex :: ContentType
speex = ContentType
          "Speex"                   -- label
          ["audio/x-speex"]         -- mime
          (L.isPrefixOf speexIdent) -- identify
          3                         -- headers
          3                         -- preroll
          (Just (\d -> intRate (le32At 36 d))) -- granulerate
          Nothing                   -- granuleshift
          speexMetadata
          
-- speexIdent = 'Speex   '
speexIdent :: L.ByteString
speexIdent = L.pack [0x53, 0x70, 0x65, 0x65, 0x78, 0x20, 0x20, 0x20]

-- Extract sample rate from Speex BOS header
speexMetadata :: L.ByteString -> MessageHeaders
speexMetadata d = MessageHeaders (fromList headerVals)
  where headerVals = [samplerate, channels]
        samplerate = ("Audio-Samplerate", [printf "%d Hz" srate])
        channels = ("Audio-Channels", [show c])
        srate = (le32At 36 d) :: Int
        c = (le32At 48 d) :: Int

------------------------------------------------------------
-- FLAC
--

flac :: ContentType
flac = ContentType
            "FLAC"                     -- label
            ["audio/x-flac"]           -- mime
            (L.isPrefixOf flacIdent)   -- identify
            3                          -- headers
            0                          -- preroll
            (Just flacGranulerate)     -- granulerate
            Nothing                    -- granuleshift
            flacMetadata
          
-- flacIdent = 0x7F:"FLAC"
flacIdent :: L.ByteString
flacIdent = L.pack [0x7f, 0x46, 0x4c, 0x41, 0x43, 0x01]

-- Extract sample rate from OggPCM2 BOS header
flacMetadata :: L.ByteString -> MessageHeaders
flacMetadata d = MessageHeaders (fromList headerVals)
  where headerVals = [samplerate, channels]
        samplerate = ("Audio-Samplerate", [(show srate) ++ " Hz"])
        channels = ("Audio-Channels", [show c])
        srate = flacGranulerate d
        c = 1 + (u8At 29 d `shiftR` 1) .&. 0x7 :: Int

flacGranulerate :: L.ByteString -> Granulerate
flacGranulerate d = intRate $ h27 .|. h28 .|. h29
  where
        h27 = (u8At 27 d) `shiftL` 12
        h28 = (u8At 28 d) `shiftL` 4
        h29 = (u8At 29 d .&. 0xf0) `shiftR` 4

------------------------------------------------------------
-- OggPCM2: http://wiki.xiph.org/index.php/OggPCM2
--

oggpcm2 :: ContentType
oggpcm2 = ContentType
            "PCM"                       -- label
            ["audio/x-ogg-pcm"]         -- mime
            (L.isPrefixOf oggpcm2Ident) -- identify
            3                           -- headers
            0                           -- preroll
            (Just (\d -> intRate (be32At 16 d))) -- granulerate
            Nothing                     -- granuleshift
            oggpcm2Metadata
          
-- oggpcm2Ident = 'PCM     '
oggpcm2Ident :: L.ByteString
oggpcm2Ident = L.pack [0x50, 0x43, 0x4D, 0x20, 0x20, 0x20, 0x20, 0x20]

-- Extract sample rate from OggPCM2 BOS header
oggpcm2Metadata :: L.ByteString -> MessageHeaders
oggpcm2Metadata d = MessageHeaders (fromList headerVals)
  where headerVals = [samplerate, channels]
        samplerate = ("Audio-Samplerate", [printf "%d Hz" srate])
        channels = ("Audio-Channels", [show c])
        srate = (be32At 16 d) :: Int
        c = (u8At 21 d) :: Int
