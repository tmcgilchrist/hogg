--
-- Module      : Granulerate
-- Copyright   : (c) Conrad Parker 2006
-- License     : BSD-style
-- Maintainer  : conradp@cse.unsw.edu.au
-- Stability   : experimental
-- Portability : portable

module Ogg.Granulerate (
  Granulerate (..),
  intRate
) where

import Data.Ratio

------------------------------------------------------------
-- Types
--

newtype Granulerate = Granulerate Rational

------------------------------------------------------------
-- Granulerate functions
--

intRate :: Integer -> Granulerate
intRate x = Granulerate (x % 1)

instance Show Granulerate where
  show (Granulerate r)
    | d == 1    = show n
    | otherwise = show r
    where n = numerator r
          d = denominator r
