-- DO NOT EDIT: This file is automatically generated by the internal tool ucd2haskell.

{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_HADDOCK hide #-}

-----------------------------------------------------------------------------
-- |
-- Module      : GHC.Unicode.Internal.Version
-- Copyright   : (c) 2020 Composewell Technologies and Contributors
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : internal
-----------------------------------------------------------------------------

module GHC.Unicode.Internal.Version
(unicodeVersion)
where

import {-# SOURCE #-} Data.Version

-- | Version of Unicode standard used by @base@:
-- [15.0.0](https://www.unicode.org/versions/Unicode15.0.0/).
--
-- @since 4.15.0.0
unicodeVersion :: Version
unicodeVersion = makeVersion [15, 0, 0]
