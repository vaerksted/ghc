{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.StgToJS.Linker.Opt
-- Copyright   :  (c) The University of Glasgow 2001
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Jeffrey Young  <jeffrey.young@iohk.io>
--                Luite Stegeman <luite.stegeman@iohk.io>
--                Sylvain Henry  <sylvain.henry@iohk.io>
-- Stability   :  experimental
--
-- Optimization pass at link time
--
--
--
-----------------------------------------------------------------------------
module GHC.StgToJS.Linker.Opt
  ( pretty
  , ghcjsRenderJs
  )
where

import GHC.Prelude
import GHC.Int
import GHC.Exts

import GHC.JS.Syntax
import GHC.JS.Ppr

import GHC.Utils.Ppr      as PP
import GHC.Data.FastString
import GHC.Types.Unique.Map

import Data.List (sortOn)
import Data.Char (isAlpha,isDigit,ord)
import qualified Data.ByteString.Short as SBS

pretty :: JStat -> Doc
pretty = jsToDocR ghcjsRenderJs

ghcjsRenderJs :: RenderJs
ghcjsRenderJs = defaultRenderJs
  { renderJsV = ghcjsRenderJsV
  , renderJsS = ghcjsRenderJsS
  , renderJsI = ghcjsRenderJsI
  }

hdd :: SBS.ShortByteString
hdd = SBS.pack (map (fromIntegral . ord) "h$$")

ghcjsRenderJsI :: RenderJs -> Ident -> Doc
ghcjsRenderJsI _ (TxtI fs)
  -- Fresh symbols are prefixed with "h$$". They aren't explicitly referred by
  -- name in user code, only in compiled code. Hence we can rename them if we do
  -- it consistently in all the linked code.
  --
  -- These symbols are usually very large because their name includes the
  -- unit-id, the module name, and some unique number. So we rename these
  -- symbols with a much shorter globally unique number.
  --
  -- Here we reuse their FastString unique for this purpose! Note that it only
  -- works if we pretty-print all the JS code linked together at once, which we
  -- currently do. GHCJS used to maintain a CompactorState to support
  -- incremental linking: it contained the mapping between original symbols and
  -- their renaming.
  | hdd `SBS.isPrefixOf` fastStringToShortByteString fs
  , u <- uniqueOfFS fs
  = text "h$$" <> hexDoc (fromIntegral u)
  | otherwise
  = ftext fs

-- | Render as an hexadecimal number in reversed order (because it's faster and we
-- don't care about the actual value).
hexDoc :: Word -> Doc
hexDoc 0 = char '0'
hexDoc v = text $ go v
  where
    sym (I# i) = C# (indexCharOffAddr# chars i)
    chars = "0123456789abcdef"#
    go = \case
      0 -> []
      n -> sym (fromIntegral (n .&. 0x0F))
           : sym (fromIntegral ((n .&. 0xF0) `shiftR` 4))
           : go (n `shiftR` 8)




-- attempt to resugar some of the common constructs
ghcjsRenderJsS :: RenderJs -> JStat -> Doc
ghcjsRenderJsS r s = renderJsS defaultRenderJs r s

-- don't quote keys in our object literals, so closure compiler works
ghcjsRenderJsV :: RenderJs -> JVal -> Doc
ghcjsRenderJsV r (JHash m)
  | isNullUniqMap m = text "{}"
  | otherwise       = braceNest . PP.fsep . punctuate comma .
                          map (\(x,y) -> quoteIfRequired x <> PP.colon <+> jsToDocR r y)
                          -- nonDetEltsUniqMap doesn't introduce non-determinism here because
                          -- we sort the elements lexically
                          . sortOn (LexicalFastString . fst) $ nonDetUniqMapToList m
  where
    quoteIfRequired :: FastString -> Doc
    quoteIfRequired x
      | isUnquotedKey x = ftext x
      | otherwise       = PP.squotes (ftext x)

    isUnquotedKey :: FastString -> Bool
    isUnquotedKey fs = case unpackFS fs of
      []       -> False
      s@(c:cs) -> all isDigit s || (validFirstIdent c && all validOtherIdent cs)

    validFirstIdent c = c == '_' || c == '$' || isAlpha c
    validOtherIdent c = isAlpha c || isDigit c

ghcjsRenderJsV r v = renderJsV defaultRenderJs r v
