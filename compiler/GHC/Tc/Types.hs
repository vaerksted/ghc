
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms            #-}

{-
(c) The University of Glasgow 2006-2012
(c) The GRASP Project, Glasgow University, 1992-2002

-}

-- | Various types used during typechecking.
--
-- Please see "GHC.Tc.Utils.Monad" as well for operations on these types. You probably
-- want to import it, instead of this module.
--
-- All the monads exported here are built on top of the same IOEnv monad. The
-- monad functions like a Reader monad in the way it passes the environment
-- around. This is done to allow the environment to be manipulated in a stack
-- like fashion when entering expressions... etc.
--
-- For state that is global and should be returned at the end (e.g not part
-- of the stack mechanism), you should use a TcRef (= IORef) to store them.
module GHC.Tc.Types(
        TcRnIf, TcRn, TcM, RnM, IfM, IfL, IfG, -- The monad is opaque outside this module
        TcRef,

        -- The environment types
        Env(..),
        TcGblEnv(..), TcLclEnv(..),
        setLclEnvTcLevel, getLclEnvTcLevel,
        setLclEnvLoc, getLclEnvLoc, lclEnvInGeneratedCode,
        IfGblEnv(..), IfLclEnv(..),
        tcVisibleOrphanMods,
        RewriteEnv(..),

        -- Frontend types (shouldn't really be here)
        FrontendResult(..),

        -- Renamer types
        ErrCtxt, pushErrCtxt, pushErrCtxtSameOrigin,
        ImportAvails(..), emptyImportAvails, plusImportAvails,
        WhereFrom(..), mkModDeps,

        -- Typechecker types
        TcTypeEnv, TcBinderStack, TcBinder(..),
        TcTyThing(..), tcTyThingTyCon_maybe,
        PromotionErr(..),
        IdBindingInfo(..), ClosedTypeId, RhsNames,
        IsGroupClosed(..),
        SelfBootInfo(..), bootExports,
        tcTyThingCategory, pprTcTyThingCategory,
        peCategory, pprPECategory,
        CompleteMatch, CompleteMatches,

        -- Template Haskell
        ThStage(..), SpliceType(..), PendingStuff(..),
        topStage, topAnnStage, topSpliceStage,
        ThLevel, impLevel, outerLevel, thLevel,
        ForeignSrcLang(..), THDocs, DocLoc(..),
        ThBindEnv,

        -- Arrows
        ArrowCtxt(..),

        -- TcSigInfo
        TcSigFun, TcSigInfo(..), TcIdSigInfo(..),
        TcIdSigInst(..), TcPatSynInfo(..),
        isPartialSig, hasCompleteSig,

        -- Misc other types
        TcId, TcIdSet,
        NameShape(..),
        removeBindingShadowing,
        getPlatform,

        -- Constraint solver plugins
        TcPlugin(..),
        TcPluginSolveResult(TcPluginContradiction, TcPluginOk, ..),
        TcPluginRewriteResult(..),
        TcPluginSolver, TcPluginRewriter,
        TcPluginM(runTcPluginM), unsafeTcPluginTcM,

        -- Defaulting plugin
        DefaultingPlugin(..), DefaultingProposal(..),
        FillDefaulting, DefaultingPluginResult,

        -- Role annotations
        RoleAnnotEnv, emptyRoleAnnotEnv, mkRoleAnnotEnv,
        lookupRoleAnnot, getRoleAnnots,

        -- Linting
        lintGblEnv,

        -- Diagnostics
        TcRnMessage
  ) where

import GHC.Prelude
import GHC.Platform

import GHC.Driver.Env
import GHC.Driver.Config.Core.Lint
import GHC.Driver.Session
import {-# SOURCE #-} GHC.Driver.Hooks

import GHC.Hs

import GHC.Tc.Utils.TcType
import GHC.Tc.Types.Constraint
import GHC.Tc.Types.Origin
import GHC.Tc.Types.Evidence
import {-# SOURCE #-} GHC.Tc.Errors.Hole.FitTypes ( HoleFitPlugin )
import GHC.Tc.Errors.Types

import GHC.Core.Reduction ( Reduction(..) )
import GHC.Core.Type
import GHC.Core.TyCon  ( TyCon, tyConKind )
import GHC.Core.PatSyn ( PatSyn )
import GHC.Core.Lint   ( lintAxioms )
import GHC.Core.UsageEnv
import GHC.Core.InstEnv
import GHC.Core.FamInstEnv
import GHC.Core.Predicate

import GHC.Types.Id         ( idType, idName )
import GHC.Types.Fixity.Env
import GHC.Types.Annotations
import GHC.Types.CompleteMatch
import GHC.Types.Name.Reader
import GHC.Types.Name
import GHC.Types.Name.Env
import GHC.Types.Name.Set
import GHC.Types.Avail
import GHC.Types.Var
import GHC.Types.Var.Env
import GHC.Types.TypeEnv
import GHC.Types.TyThing
import GHC.Types.SourceFile
import GHC.Types.SrcLoc
import GHC.Types.Var.Set
import GHC.Types.Unique.FM
import GHC.Types.Basic
import GHC.Types.CostCentre.State
import GHC.Types.HpcInfo

import GHC.Data.IOEnv
import GHC.Data.Bag
import GHC.Data.List.SetOps

import GHC.Unit
import GHC.Unit.Module.Warnings
import GHC.Unit.Module.Deps
import GHC.Unit.Module.ModDetails

import GHC.Utils.Error
import GHC.Utils.Outputable
import GHC.Utils.Fingerprint
import GHC.Utils.Misc
import GHC.Utils.Panic
import GHC.Utils.Logger

import GHC.Builtin.Names ( isUnboundName )

import Data.Set      ( Set )
import qualified Data.Set as S
import Data.Dynamic  ( Dynamic )
import Data.Map ( Map )
import Data.Typeable ( TypeRep )
import Data.Maybe    ( mapMaybe )
import GHCi.Message
import GHCi.RemoteTypes

import qualified Language.Haskell.TH as TH
import GHC.Driver.Env.KnotVars
import GHC.Linker.Types

-- | A 'NameShape' is a substitution on 'Name's that can be used
-- to refine the identities of a hole while we are renaming interfaces
-- (see "GHC.Iface.Rename").  Specifically, a 'NameShape' for
-- 'ns_module_name' @A@, defines a mapping from @{A.T}@
-- (for some 'OccName' @T@) to some arbitrary other 'Name'.
--
-- The most intriguing thing about a 'NameShape', however, is
-- how it's constructed.  A 'NameShape' is *implied* by the
-- exported 'AvailInfo's of the implementor of an interface:
-- if an implementor of signature @\<H>@ exports @M.T@, you implicitly
-- define a substitution from @{H.T}@ to @M.T@.  So a 'NameShape'
-- is computed from the list of 'AvailInfo's that are exported
-- by the implementation of a module, or successively merged
-- together by the export lists of signatures which are joining
-- together.
--
-- It's not the most obvious way to go about doing this, but it
-- does seem to work!
--
-- NB: Can't boot this and put it in NameShape because then we
-- start pulling in too many DynFlags things.
data NameShape = NameShape {
        ns_mod_name :: ModuleName,
        ns_exports :: [AvailInfo],
        ns_map :: OccEnv Name
    }


{-
************************************************************************
*                                                                      *
               Standard monad definition for TcRn
    All the combinators for the monad can be found in GHC.Tc.Utils.Monad
*                                                                      *
************************************************************************

The monad itself has to be defined here, because it is mentioned by ErrCtxt
-}

type TcRnIf a b = IOEnv (Env a b)
type TcRn       = TcRnIf TcGblEnv TcLclEnv    -- Type inference
type IfM lcl    = TcRnIf IfGblEnv lcl         -- Iface stuff
type IfG        = IfM ()                      --    Top level
type IfL        = IfM IfLclEnv                --    Nested

-- TcRn is the type-checking and renaming monad: the main monad that
-- most type-checking takes place in.  The global environment is
-- 'TcGblEnv', which tracks all of the top-level type-checking
-- information we've accumulated while checking a module, while the
-- local environment is 'TcLclEnv', which tracks local information as
-- we move inside expressions.

-- | Historical "renaming monad" (now it's just 'TcRn').
type RnM  = TcRn

-- | Historical "type-checking monad" (now it's just 'TcRn').
type TcM  = TcRn

-- We 'stack' these envs through the Reader like monad infrastructure
-- as we move into an expression (although the change is focused in
-- the lcl type).
data Env gbl lcl
  = Env {
        env_top  :: !HscEnv, -- Top-level stuff that never changes
                             -- Includes all info about imported things
                             -- BangPattern is to fix leak, see #15111

        env_um   :: {-# UNPACK #-} !Char,   -- Mask for Uniques

        env_gbl  :: gbl,     -- Info about things defined at the top level
                             -- of the module being compiled

        env_lcl  :: lcl      -- Nested stuff; changes as we go into
    }

instance ContainsDynFlags (Env gbl lcl) where
    extractDynFlags env = hsc_dflags (env_top env)

instance ContainsHooks (Env gbl lcl) where
    extractHooks env = hsc_hooks (env_top env)

instance ContainsLogger (Env gbl lcl) where
    extractLogger env = hsc_logger (env_top env)

instance ContainsModule gbl => ContainsModule (Env gbl lcl) where
    extractModule env = extractModule (env_gbl env)

{-
************************************************************************
*                                                                      *
*                            RewriteEnv
*                     The rewriting environment
*                                                                      *
************************************************************************
-}

-- | A 'RewriteEnv' carries the necessary context for performing rewrites
-- (i.e. type family reductions and following filled-in metavariables)
-- in the solver.
data RewriteEnv
  = RE { re_loc     :: !CtLoc
       -- ^ In which context are we rewriting?
       --
       -- Type-checking plugins might want to use this location information
       -- when emitting new Wanted constraints when rewriting type family
       -- applications. This ensures that such Wanted constraints will,
       -- when unsolved, give rise to error messages with the
       -- correct source location.

       -- Within GHC, we use this field to keep track of reduction depth.
       -- See Note [Rewriter CtLoc] in GHC.Tc.Solver.Rewrite.
       , re_flavour :: !CtFlavour
       , re_eq_rel  :: !EqRel
       -- ^ At what role are we rewriting?
       --
       -- See Note [Rewriter EqRels] in GHC.Tc.Solver.Rewrite

       , re_rewriters :: !(TcRef RewriterSet)  -- ^ See Note [Wanteds rewrite Wanteds]
       }
-- RewriteEnv is mostly used in @GHC.Tc.Solver.Rewrite@, but it is defined
-- here so that it can also be passed to rewriting plugins.
-- See the 'tcPluginRewrite' field of 'TcPlugin'.


{-
************************************************************************
*                                                                      *
                The interface environments
              Used when dealing with IfaceDecls
*                                                                      *
************************************************************************
-}

data IfGblEnv
  = IfGblEnv {
        -- Some information about where this environment came from;
        -- useful for debugging.
        if_doc :: SDoc,
        -- The type environment for the module being compiled,
        -- in case the interface refers back to it via a reference that
        -- was originally a hi-boot file.
        -- We need the module name so we can test when it's appropriate
        -- to look in this env.
        -- See Note [Tying the knot] in GHC.IfaceToCore
        if_rec_types :: (KnotVars (IfG TypeEnv))
                -- Allows a read effect, so it can be in a mutable
                -- variable; c.f. handling the external package type env
                -- Nothing => interactive stuff, no loops possible
    }

data IfLclEnv
  = IfLclEnv {
        -- The module for the current IfaceDecl
        -- So if we see   f = \x -> x
        -- it means M.f = \x -> x, where M is the if_mod
        -- NB: This is a semantic module, see
        -- Note [Identity versus semantic module]
        if_mod :: !Module,

        -- Whether or not the IfaceDecl came from a boot
        -- file or not; we'll use this to choose between
        -- NoUnfolding and BootUnfolding
        if_boot :: IsBootInterface,

        -- The field is used only for error reporting
        -- if (say) there's a Lint error in it
        if_loc :: SDoc,
                -- Where the interface came from:
                --      .hi file, or GHCi state, or ext core
                -- plus which bit is currently being examined

        if_nsubst :: Maybe NameShape,

        -- This field is used to make sure "implicit" declarations
        -- (anything that cannot be exported in mi_exports) get
        -- wired up correctly in typecheckIfacesForMerging.  Most
        -- of the time it's @Nothing@.  See Note [Resolving never-exported Names]
        -- in GHC.IfaceToCore.
        if_implicits_env :: Maybe TypeEnv,

        if_tv_env  :: FastStringEnv TyVar,     -- Nested tyvar bindings
        if_id_env  :: FastStringEnv Id         -- Nested id binding
    }

{-
************************************************************************
*                                                                      *
                Global typechecker environment
*                                                                      *
************************************************************************
-}

-- | 'FrontendResult' describes the result of running the frontend of a Haskell
-- module. Currently one always gets a 'FrontendTypecheck', since running the
-- frontend involves typechecking a program. hs-sig merges are not handled here.
--
-- This data type really should be in GHC.Driver.Env, but it needs
-- to have a TcGblEnv which is only defined here.
data FrontendResult
        = FrontendTypecheck TcGblEnv

-- Note [Identity versus semantic module]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- When typechecking an hsig file, it is convenient to keep track
-- of two different "this module" identifiers:
--
--      - The IDENTITY module is simply thisPackage + the module
--        name; i.e. it uniquely *identifies* the interface file
--        we're compiling.  For example, p[A=<A>]:A is an
--        identity module identifying the requirement named A
--        from library p.
--
--      - The SEMANTIC module, which is the actual module that
--        this signature is intended to represent (e.g. if
--        we have a identity module p[A=base:Data.IORef]:A,
--        then the semantic module is base:Data.IORef)
--
-- Which one should you use?
--
--      - In the desugarer and later phases of compilation,
--        identity and semantic modules coincide, since we never compile
--        signatures (we just generate blank object files for
--        hsig files.)
--
--        A corollary of this is that the following invariant holds at any point
--        past desugaring,
--
--            if I have a Module, this_mod, in hand representing the module
--            currently being compiled,
--            then moduleUnit this_mod == thisPackage dflags
--
--      - For any code involving Names, we want semantic modules.
--        See lookupIfaceTop in GHC.Iface.Env, mkIface and addFingerprints
--        in GHC.Iface.{Make,Recomp}, and tcLookupGlobal in GHC.Tc.Utils.Env
--
--      - When reading interfaces, we want the identity module to
--        identify the specific interface we want (such interfaces
--        should never be loaded into the EPS).  However, if a
--        hole module <A> is requested, we look for A.hi
--        in the home library we are compiling.  (See GHC.Iface.Load.)
--        Similarly, in GHC.Rename.Names we check for self-imports using
--        identity modules, to allow signatures to import their implementor.
--
--      - For recompilation avoidance, you want the identity module,
--        since that will actually say the specific interface you
--        want to track (and recompile if it changes)

-- | 'TcGblEnv' describes the top-level of the module at the
-- point at which the typechecker is finished work.
-- It is this structure that is handed on to the desugarer
-- For state that needs to be updated during the typechecking
-- phase and returned at end, use a 'TcRef' (= 'IORef').
data TcGblEnv
  = TcGblEnv {
        tcg_mod     :: Module,         -- ^ Module being compiled
        tcg_semantic_mod :: Module,    -- ^ If a signature, the backing module
            -- See also Note [Identity versus semantic module]
        tcg_src     :: HscSource,
          -- ^ What kind of module (regular Haskell, hs-boot, hsig)

        tcg_rdr_env :: GlobalRdrEnv,   -- ^ Top level envt; used during renaming
        tcg_default :: Maybe [Type],
          -- ^ Types used for defaulting. @Nothing@ => no @default@ decl

        tcg_fix_env :: FixityEnv,      -- ^ Just for things in this module

        tcg_type_env :: TypeEnv,
          -- ^ Global type env for the module we are compiling now.  All
          -- TyCons and Classes (for this module) end up in here right away,
          -- along with their derived constructors, selectors.
          --
          -- (Ids defined in this module start in the local envt, though they
          --  move to the global envt during zonking)
          --
          -- NB: for what "things in this module" means, see
          -- Note [The interactive package] in "GHC.Runtime.Context"

        tcg_type_env_var :: KnotVars (IORef TypeEnv),
                -- Used only to initialise the interface-file
                -- typechecker in initIfaceTcRn, so that it can see stuff
                -- bound in this module when dealing with hi-boot recursions
                -- Updated at intervals (e.g. after dealing with types and classes)

        tcg_inst_env     :: !InstEnv,
          -- ^ Instance envt for all /home-package/ modules;
          -- Includes the dfuns in tcg_insts
          -- NB. BangPattern is to fix a leak, see #15111
        tcg_fam_inst_env :: !FamInstEnv, -- ^ Ditto for family instances
          -- NB. BangPattern is to fix a leak, see #15111
        tcg_ann_env      :: AnnEnv,     -- ^ And for annotations

                -- Now a bunch of things about this module that are simply
                -- accumulated, but never consulted until the end.
                -- Nevertheless, it's convenient to accumulate them along
                -- with the rest of the info from this module.
        tcg_exports :: [AvailInfo],     -- ^ What is exported
        tcg_imports :: ImportAvails,
          -- ^ Information about what was imported from where, including
          -- things bound in this module. Also store Safe Haskell info
          -- here about transitive trusted package requirements.
          --
          -- There are not many uses of this field, so you can grep for
          -- all them.
          --
          -- The ImportAvails records information about the following
          -- things:
          --
          --    1. All of the modules you directly imported (tcRnImports)
          --    2. The orphans (only!) of all imported modules in a GHCi
          --       session (runTcInteractive)
          --    3. The module that instantiated a signature
          --    4. Each of the signatures that merged in
          --
          -- It is used in the following ways:
          --    - imp_orphs is used to determine what orphan modules should be
          --      visible in the context (tcVisibleOrphanMods)
          --    - imp_finsts is used to determine what family instances should
          --      be visible (tcExtendLocalFamInstEnv)
          --    - To resolve the meaning of the export list of a module
          --      (tcRnExports)
          --    - imp_mods is used to compute usage info (mkIfaceTc, deSugar)
          --    - imp_trust_own_pkg is used for Safe Haskell in interfaces
          --      (mkIfaceTc, as well as in "GHC.Driver.Main")
          --    - To create the Dependencies field in interface (mkDependencies)

          -- These three fields track unused bindings and imports
          -- See Note [Tracking unused binding and imports]
        tcg_dus       :: DefUses,
        tcg_used_gres :: TcRef [GlobalRdrElt],
        tcg_keep      :: TcRef NameSet,

        tcg_th_used :: TcRef Bool,
          -- ^ @True@ \<=> Template Haskell syntax used.
          --
          -- We need this so that we can generate a dependency on the
          -- Template Haskell package, because the desugarer is going
          -- to emit loads of references to TH symbols.  The reference
          -- is implicit rather than explicit, so we have to zap a
          -- mutable variable.

        tcg_th_splice_used :: TcRef Bool,
          -- ^ @True@ \<=> A Template Haskell splice was used.
          --
          -- Splices disable recompilation avoidance (see #481)

        tcg_th_needed_deps :: TcRef ([Linkable], PkgsLoaded),
          -- ^ The set of runtime dependencies required by this module
          -- See Note [Object File Dependencies]

        tcg_dfun_n  :: TcRef OccSet,
          -- ^ Allows us to choose unique DFun names.

        tcg_merged :: [(Module, Fingerprint)],
          -- ^ The requirements we merged with; we always have to recompile
          -- if any of these changed.

        -- The next fields accumulate the payload of the module
        -- The binds, rules and foreign-decl fields are collected
        -- initially in un-zonked form and are finally zonked in tcRnSrcDecls

        tcg_rn_exports :: Maybe [(LIE GhcRn, Avails)],
                -- Nothing <=> no explicit export list
                -- Is always Nothing if we don't want to retain renamed
                -- exports.
                -- If present contains each renamed export list item
                -- together with its exported names.

        tcg_rn_imports :: [LImportDecl GhcRn],
                -- Keep the renamed imports regardless.  They are not
                -- voluminous and are needed if you want to report unused imports

        tcg_rn_decls :: Maybe (HsGroup GhcRn),
          -- ^ Renamed decls, maybe.  @Nothing@ \<=> Don't retain renamed
          -- decls.

        tcg_dependent_files :: TcRef [FilePath], -- ^ dependencies from addDependentFile

        tcg_th_topdecls :: TcRef [LHsDecl GhcPs],
        -- ^ Top-level declarations from addTopDecls

        tcg_th_foreign_files :: TcRef [(ForeignSrcLang, FilePath)],
        -- ^ Foreign files emitted from TH.

        tcg_th_topnames :: TcRef NameSet,
        -- ^ Exact names bound in top-level declarations in tcg_th_topdecls

        tcg_th_modfinalizers :: TcRef [(TcLclEnv, ThModFinalizers)],
        -- ^ Template Haskell module finalizers.
        --
        -- They can use particular local environments.

        tcg_th_coreplugins :: TcRef [String],
        -- ^ Core plugins added by Template Haskell code.

        tcg_th_state :: TcRef (Map TypeRep Dynamic),
        tcg_th_remote_state :: TcRef (Maybe (ForeignRef (IORef QState))),
        -- ^ Template Haskell state

        tcg_th_docs   :: TcRef THDocs,
        -- ^ Docs added in Template Haskell via @putDoc@.

        tcg_ev_binds  :: Bag EvBind,        -- Top-level evidence bindings

        -- Things defined in this module, or (in GHCi)
        -- in the declarations for a single GHCi command.
        -- For the latter, see Note [The interactive package] in
        -- GHC.Runtime.Context
        tcg_tr_module :: Maybe Id,   -- Id for $trModule :: GHC.Unit.Module
                                             -- for which every module has a top-level defn
                                             -- except in GHCi in which case we have Nothing
        tcg_binds     :: LHsBinds GhcTc,     -- Value bindings in this module
        tcg_sigs      :: NameSet,            -- ...Top-level names that *lack* a signature
        tcg_imp_specs :: [LTcSpecPrag],      -- ...SPECIALISE prags for imported Ids
        tcg_warns     :: (Warnings GhcRn), -- ...Warnings and deprecations
        tcg_anns      :: [Annotation],       -- ...Annotations
        tcg_tcs       :: [TyCon],            -- ...TyCons and Classes
        tcg_ksigs     :: NameSet,            -- ...Top-level TyCon names that *lack* a signature
        tcg_insts     :: [ClsInst],          -- ...Instances
        tcg_fam_insts :: [FamInst],          -- ...Family instances
        tcg_rules     :: [LRuleDecl GhcTc],  -- ...Rules
        tcg_fords     :: [LForeignDecl GhcTc], -- ...Foreign import & exports
        tcg_patsyns   :: [PatSyn],            -- ...Pattern synonyms

        tcg_doc_hdr   :: Maybe (LHsDoc GhcRn), -- ^ Maybe Haddock header docs
        tcg_hpc       :: !AnyHpcUsage,       -- ^ @True@ if any part of the
                                             --  prog uses hpc instrumentation.
           -- NB. BangPattern is to fix a leak, see #15111

        tcg_self_boot :: SelfBootInfo,       -- ^ Whether this module has a
                                             -- corresponding hi-boot file

        tcg_main      :: Maybe Name,         -- ^ The Name of the main
                                             -- function, if this module is
                                             -- the main module.

        tcg_safe_infer :: TcRef Bool,
        -- ^ Has the typechecker inferred this module as -XSafe (Safe Haskell)?
        -- See Note [Safe Haskell Overlapping Instances Implementation],
        -- although this is used for more than just that failure case.

        tcg_safe_infer_reasons :: TcRef (Messages TcRnMessage),
        -- ^ Unreported reasons why tcg_safe_infer is False.
        -- INVARIANT: If this Messages is non-empty, then tcg_safe_infer is False.
        -- It may be that tcg_safe_infer is False but this is empty, if no reasons
        -- are supplied (#19714), or if those reasons have already been
        -- reported by GHC.Driver.Main.markUnsafeInfer

        tcg_tc_plugin_solvers :: [TcPluginSolver],
        -- ^ A list of user-defined type-checking plugins for constraint solving.

        tcg_tc_plugin_rewriters :: UniqFM TyCon [TcPluginRewriter],
        -- ^ A collection of all the user-defined type-checking plugins for rewriting
        -- type family applications, collated by their type family 'TyCon's.

        tcg_defaulting_plugins :: [FillDefaulting],
        -- ^ A list of user-defined plugins for type defaulting plugins.

        tcg_hf_plugins :: [HoleFitPlugin],
        -- ^ A list of user-defined plugins for hole fit suggestions.

        tcg_top_loc :: RealSrcSpan,
        -- ^ The RealSrcSpan this module came from

        tcg_static_wc :: TcRef WantedConstraints,
          -- ^ Wanted constraints of static forms.
        -- See Note [Constraints in static forms].
        tcg_complete_matches :: !CompleteMatches,

        -- ^ Tracking indices for cost centre annotations
        tcg_cc_st   :: TcRef CostCentreState,

        tcg_next_wrapper_num :: TcRef (ModuleEnv Int)
        -- ^ See Note [Generating fresh names for FFI wrappers]
    }

-- NB: topModIdentity, not topModSemantic!
-- Definition sites of orphan identities will be identity modules, not semantic
-- modules.

-- Note [Constraints in static forms]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- When a static form produces constraints like
--
-- f :: StaticPtr (Bool -> String)
-- f = static show
--
-- we collect them in tcg_static_wc and resolve them at the end
-- of type checking. They need to be resolved separately because
-- we don't want to resolve them in the context of the enclosing
-- expression. Consider
--
-- g :: Show a => StaticPtr (a -> String)
-- g = static show
--
-- If the @Show a0@ constraint that the body of the static form produces was
-- resolved in the context of the enclosing expression, then the body of the
-- static form wouldn't be closed because the Show dictionary would come from
-- g's context instead of coming from the top level.

tcVisibleOrphanMods :: TcGblEnv -> ModuleSet
tcVisibleOrphanMods tcg_env
    = mkModuleSet (tcg_mod tcg_env : imp_orphs (tcg_imports tcg_env))

instance ContainsModule TcGblEnv where
    extractModule env = tcg_semantic_mod env

data SelfBootInfo
  = NoSelfBoot    -- No corresponding hi-boot file
  | SelfBoot
       { sb_mds :: ModDetails   -- There was a hi-boot file,
       , sb_tcs :: NameSet }    -- defining these TyCons,
-- What is sb_tcs used for?  See Note [Extra dependencies from .hs-boot files]
-- in GHC.Rename.Module

bootExports :: SelfBootInfo -> NameSet
bootExports boot =
  case boot of
    NoSelfBoot -> emptyNameSet
    SelfBoot { sb_mds = mds} ->
      let exports = md_exports mds
      in availsToNameSet exports



{- Note [Tracking unused binding and imports]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We gather three sorts of usage information

 * tcg_dus :: DefUses (defs/uses)
      Records what is defined in this module and what is used.

      Records *defined* Names (local, top-level)
          and *used*    Names (local or imported)

      Used (a) to report "defined but not used"
               (see GHC.Rename.Names.reportUnusedNames)
           (b) to generate version-tracking usage info in interface
               files (see GHC.Iface.Make.mkUsedNames)
   This usage info is mainly gathered by the renamer's
   gathering of free-variables

 * tcg_used_gres :: TcRef [GlobalRdrElt]
      Records occurrences of imported entities.

      Used only to report unused import declarations

      Records each *occurrence* an *imported* (not locally-defined) entity.
      The occurrence is recorded by keeping a GlobalRdrElt for it.
      These is not the GRE that is in the GlobalRdrEnv; rather it
      is recorded *after* the filtering done by pickGREs.  So it reflect
      /how that occurrence is in scope/.   See Note [GRE filtering] in
      RdrName.

  * tcg_keep :: TcRef NameSet
      Records names of the type constructors, data constructors, and Ids that
      are used by the constraint solver.

      The typechecker may use find that some imported or
      locally-defined things are used, even though they
      do not appear to be mentioned in the source code:

      (a) The to/from functions for generic data types

      (b) Top-level variables appearing free in the RHS of an
          orphan rule

      (c) Top-level variables appearing free in a TH bracket
          See Note [Keeping things alive for Template Haskell]
          in GHC.Rename.Splice

      (d) The data constructor of a newtype that is used
          to solve a Coercible instance (e.g. #10347). Example
              module T10347 (N, mkN) where
                import Data.Coerce
                newtype N a = MkN Int
                mkN :: Int -> N a
                mkN = coerce

          Then we wish to record `MkN` as used, since it is (morally)
          used to perform the coercion in `mkN`. To do so, the
          Coercible solver updates tcg_keep's TcRef whenever it
          encounters a use of `coerce` that crosses newtype boundaries.

      (e) Record fields that are used to solve HasField constraints
          (see Note [Unused name reporting and HasField] in GHC.Tc.Instance.Class)

      The tcg_keep field is used in two distinct ways:

      * Desugar.addExportFlagsAndRules.  Where things like (a-c) are locally
        defined, we should give them an Exported flag, so that the
        simplifier does not discard them as dead code, and so that they are
        exposed in the interface file (but not to export to the user).

      * GHC.Rename.Names.reportUnusedNames.  Where newtype data constructors
        like (d) are imported, we don't want to report them as unused.


************************************************************************
*                                                                      *
                The local typechecker environment
*                                                                      *
************************************************************************

Note [The Global-Env/Local-Env story]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During type checking, we keep in the tcg_type_env
        * All types and classes
        * All Ids derived from types and classes (constructors, selectors)

At the end of type checking, we zonk the local bindings,
and as we do so we add to the tcg_type_env
        * Locally defined top-level Ids

Why?  Because they are now Ids not TcIds.  This final GlobalEnv is
        a) fed back (via the knot) to typechecking the
           unfoldings of interface signatures
        b) used in the ModDetails of this module
-}

data TcLclEnv           -- Changes as we move inside an expression
                        -- Discarded after typecheck/rename; not passed on to desugarer
  = TcLclEnv {
        tcl_loc        :: RealSrcSpan,     -- Source span
        tcl_ctxt       :: [ErrCtxt],       -- Error context, innermost on top
        tcl_in_gen_code :: Bool,           -- See Note [Rebindable syntax and HsExpansion]
        tcl_tclvl      :: TcLevel,

        tcl_th_ctxt    :: ThStage,         -- Template Haskell context
        tcl_th_bndrs   :: ThBindEnv,       -- and binder info
            -- The ThBindEnv records the TH binding level of in-scope Names
            -- defined in this module (not imported)
            -- We can't put this info in the TypeEnv because it's needed
            -- (and extended) in the renamer, for untyped splices

        tcl_arrow_ctxt :: ArrowCtxt,       -- Arrow-notation context

        tcl_rdr :: LocalRdrEnv,         -- Local name envt
                -- Maintained during renaming, of course, but also during
                -- type checking, solely so that when renaming a Template-Haskell
                -- splice we have the right environment for the renamer.
                --
                --   Does *not* include global name envt; may shadow it
                --   Includes both ordinary variables and type variables;
                --   they are kept distinct because tyvar have a different
                --   occurrence constructor (Name.TvOcc)
                -- We still need the unsullied global name env so that
                --   we can look up record field names

        tcl_env  :: TcTypeEnv,    -- The local type environment:
                                  -- Ids and TyVars defined in this module

        tcl_usage :: TcRef UsageEnv, -- Required multiplicity of bindings is accumulated here.


        tcl_bndrs :: TcBinderStack,   -- Used for reporting relevant bindings,
                                      -- and for tidying types

        tcl_lie  :: TcRef WantedConstraints,    -- Place to accumulate type constraints
        tcl_errs :: TcRef (Messages TcRnMessage)     -- Place to accumulate diagnostics
    }

setLclEnvTcLevel :: TcLclEnv -> TcLevel -> TcLclEnv
setLclEnvTcLevel env lvl = env { tcl_tclvl = lvl }

getLclEnvTcLevel :: TcLclEnv -> TcLevel
getLclEnvTcLevel = tcl_tclvl

setLclEnvLoc :: TcLclEnv -> RealSrcSpan -> TcLclEnv
setLclEnvLoc env loc = env { tcl_loc = loc }

getLclEnvLoc :: TcLclEnv -> RealSrcSpan
getLclEnvLoc = tcl_loc

lclEnvInGeneratedCode :: TcLclEnv -> Bool
lclEnvInGeneratedCode = tcl_in_gen_code

type ErrCtxt = (Bool, TidyEnv -> TcM (TidyEnv, SDoc))
        -- Monadic so that we have a chance
        -- to deal with bound type variables just before error
        -- message construction

        -- Bool:  True <=> this is a landmark context; do not
        --                 discard it when trimming for display

-- These are here to avoid module loops: one might expect them
-- in GHC.Tc.Types.Constraint, but they refer to ErrCtxt which refers to TcM.
-- Easier to just keep these definitions here, alongside TcM.
pushErrCtxt :: CtOrigin -> ErrCtxt -> CtLoc -> CtLoc
pushErrCtxt o err loc@(CtLoc { ctl_env = lcl })
  = loc { ctl_origin = o, ctl_env = lcl { tcl_ctxt = err : tcl_ctxt lcl } }

pushErrCtxtSameOrigin :: ErrCtxt -> CtLoc -> CtLoc
-- Just add information w/o updating the origin!
pushErrCtxtSameOrigin err loc@(CtLoc { ctl_env = lcl })
  = loc { ctl_env = lcl { tcl_ctxt = err : tcl_ctxt lcl } }

type TcTypeEnv = NameEnv TcTyThing

type ThBindEnv = NameEnv (TopLevelFlag, ThLevel)
   -- Domain = all Ids bound in this module (ie not imported)
   -- The TopLevelFlag tells if the binding is syntactically top level.
   -- We need to know this, because the cross-stage persistence story allows
   -- cross-stage at arbitrary types if the Id is bound at top level.
   --
   -- Nota bene: a ThLevel of 'outerLevel' is *not* the same as being
   -- bound at top level!  See Note [Template Haskell levels] in GHC.Tc.Gen.Splice

{- Note [Given Insts]
   ~~~~~~~~~~~~~~~~~~
Because of GADTs, we have to pass inwards the Insts provided by type signatures
and existential contexts. Consider
        data T a where { T1 :: b -> b -> T [b] }
        f :: Eq a => T a -> Bool
        f (T1 x y) = [x]==[y]

The constructor T1 binds an existential variable 'b', and we need Eq [b].
Well, we have it, because Eq a refines to Eq [b], but we can only spot that if we
pass it inwards.

-}

-- | Type alias for 'IORef'; the convention is we'll use this for mutable
-- bits of data in 'TcGblEnv' which are updated during typechecking and
-- returned at the end.
type TcRef a     = IORef a
-- ToDo: when should I refer to it as a 'TcId' instead of an 'Id'?
type TcId        = Id
type TcIdSet     = IdSet

---------------------------
-- The TcBinderStack
---------------------------

type TcBinderStack = [TcBinder]
   -- This is a stack of locally-bound ids and tyvars,
   --   innermost on top
   -- Used only in error reporting (relevantBindings in TcError),
   --   and in tidying
   -- We can't use the tcl_env type environment, because it doesn't
   --   keep track of the nesting order

data TcBinder
  = TcIdBndr
       TcId
       TopLevelFlag    -- Tells whether the binding is syntactically top-level
                       -- (The monomorphic Ids for a recursive group count
                       --  as not-top-level for this purpose.)

  | TcIdBndr_ExpType  -- Variant that allows the type to be specified as
                      -- an ExpType
       Name
       ExpType
       TopLevelFlag

  | TcTvBndr          -- e.g.   case x of P (y::a) -> blah
       Name           -- We bind the lexical name "a" to the type of y,
       TyVar          -- which might be an utterly different (perhaps
                      -- existential) tyvar

instance Outputable TcBinder where
   ppr (TcIdBndr id top_lvl)           = ppr id <> brackets (ppr top_lvl)
   ppr (TcIdBndr_ExpType id _ top_lvl) = ppr id <> brackets (ppr top_lvl)
   ppr (TcTvBndr name tv)              = ppr name <+> ppr tv

instance HasOccName TcBinder where
    occName (TcIdBndr id _)             = occName (idName id)
    occName (TcIdBndr_ExpType name _ _) = occName name
    occName (TcTvBndr name _)           = occName name

-- fixes #12177
-- Builds up a list of bindings whose OccName has not been seen before
-- i.e., If    ys  = removeBindingShadowing xs
-- then
--  - ys is obtained from xs by deleting some elements
--  - ys has no duplicate OccNames
--  - The first duplicated OccName in xs is retained in ys
-- Overloaded so that it can be used for both GlobalRdrElt in typed-hole
-- substitutions and TcBinder when looking for relevant bindings.
removeBindingShadowing :: HasOccName a => [a] -> [a]
removeBindingShadowing bindings = reverse $ fst $ foldl
    (\(bindingAcc, seenNames) binding ->
    if occName binding `elemOccSet` seenNames -- if we've seen it
        then (bindingAcc, seenNames)              -- skip it
        else (binding:bindingAcc, extendOccSet seenNames (occName binding)))
    ([], emptyOccSet) bindings


-- | Get target platform
getPlatform :: TcRnIf a b Platform
getPlatform = targetPlatform <$> getDynFlags

---------------------------
-- Template Haskell stages and levels
---------------------------

data SpliceType = Typed | Untyped

data ThStage    -- See Note [Template Haskell state diagram]
                -- and Note [Template Haskell levels] in GHC.Tc.Gen.Splice
    -- Start at:   Comp
    -- At bracket: wrap current stage in Brack
    -- At splice:  currently Brack: return to previous stage
    --             currently Comp/Splice: compile and run
  = Splice SpliceType -- Inside a top-level splice
                      -- This code will be run *at compile time*;
                      --   the result replaces the splice
                      -- Binding level = 0

  | RunSplice (TcRef [ForeignRef (TH.Q ())])
      -- Set when running a splice, i.e. NOT when renaming or typechecking the
      -- Haskell code for the splice. See Note [RunSplice ThLevel].
      --
      -- Contains a list of mod finalizers collected while executing the splice.
      --
      -- 'addModFinalizer' inserts finalizers here, and from here they are taken
      -- to construct an @HsSpliced@ annotation for untyped splices. See Note
      -- [Delaying modFinalizers in untyped splices] in GHC.Rename.Splice.
      --
      -- For typed splices, the typechecker takes finalizers from here and
      -- inserts them in the list of finalizers in the global environment.
      --
      -- See Note [Collecting modFinalizers in typed splices] in "GHC.Tc.Gen.Splice".

  | Comp        -- Ordinary Haskell code
                -- Binding level = 1

  | Brack                       -- Inside brackets
      ThStage                   --   Enclosing stage
      PendingStuff

data PendingStuff
  = RnPendingUntyped              -- Renaming the inside of an *untyped* bracket
      (TcRef [PendingRnSplice])   -- Pending splices in here

  | RnPendingTyped                -- Renaming the inside of a *typed* bracket

  | TcPending                     -- Typechecking the inside of a typed bracket
      (TcRef [PendingTcSplice])   --   Accumulate pending splices here
      (TcRef WantedConstraints)   --     and type constraints here
      QuoteWrapper                -- A type variable and evidence variable
                                  -- for the overall monad of
                                  -- the bracket. Splices are checked
                                  -- against this monad. The evidence
                                  -- variable is used for desugaring
                                  -- `lift`.


topStage, topAnnStage, topSpliceStage :: ThStage
topStage       = Comp
topAnnStage    = Splice Untyped
topSpliceStage = Splice Untyped

instance Outputable ThStage where
   ppr (Splice _)    = text "Splice"
   ppr (RunSplice _) = text "RunSplice"
   ppr Comp          = text "Comp"
   ppr (Brack s _)   = text "Brack" <> parens (ppr s)

type ThLevel = Int
    -- NB: see Note [Template Haskell levels] in GHC.Tc.Gen.Splice
    -- Incremented when going inside a bracket,
    -- decremented when going inside a splice
    -- NB: ThLevel is one greater than the 'n' in Fig 2 of the
    --     original "Template meta-programming for Haskell" paper

impLevel, outerLevel :: ThLevel
impLevel = 0    -- Imported things; they can be used inside a top level splice
outerLevel = 1  -- Things defined outside brackets

thLevel :: ThStage -> ThLevel
thLevel (Splice _)    = 0
thLevel Comp          = 1
thLevel (Brack s _)   = thLevel s + 1
thLevel (RunSplice _) = panic "thLevel: called when running a splice"
                        -- See Note [RunSplice ThLevel].

{- Note [RunSplice ThLevel]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The 'RunSplice' stage is set when executing a splice, and only when running a
splice. In particular it is not set when the splice is renamed or typechecked.

'RunSplice' is needed to provide a reference where 'addModFinalizer' can insert
the finalizer (see Note [Delaying modFinalizers in untyped splices]), and
'addModFinalizer' runs when doing Q things. Therefore, It doesn't make sense to
set 'RunSplice' when renaming or typechecking the splice, where 'Splice',
'Brack' or 'Comp' are used instead.

-}

---------------------------
-- Arrow-notation context
---------------------------

{- Note [Escaping the arrow scope]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In arrow notation, a variable bound by a proc (or enclosed let/kappa)
is not in scope to the left of an arrow tail (-<) or the head of (|..|).
For example

        proc x -> (e1 -< e2)

Here, x is not in scope in e1, but it is in scope in e2.  This can get
a bit complicated:

        let x = 3 in
        proc y -> (proc z -> e1) -< e2

Here, x and z are in scope in e1, but y is not.

We implement this by
recording the environment when passing a proc (using newArrowScope),
and returning to that (using escapeArrowScope) on the left of -< and the
head of (|..|).

All this can be dealt with by the *renamer*. But the type checker needs
to be involved too.  Example (arrowfail001)
  class Foo a where foo :: a -> ()
  data Bar = forall a. Foo a => Bar a
  get :: Bar -> ()
  get = proc x -> case x of Bar a -> foo -< a
Here the call of 'foo' gives rise to a (Foo a) constraint that should not
be captured by the pattern match on 'Bar'.  Rather it should join the
constraints from further out.  So we must capture the constraint bag
from further out in the ArrowCtxt that we push inwards.
-}

data ArrowCtxt   -- Note [Escaping the arrow scope]
  = NoArrowCtxt
  | ArrowCtxt LocalRdrEnv (TcRef WantedConstraints)


---------------------------
-- TcTyThing
---------------------------

-- | A typecheckable thing available in a local context.  Could be
-- 'AGlobal' 'TyThing', but also lexically scoped variables, etc.
-- See "GHC.Tc.Utils.Env" for how to retrieve a 'TyThing' given a 'Name'.
data TcTyThing
  = AGlobal TyThing             -- Used only in the return type of a lookup

  | ATcId           -- Ids defined in this module; may not be fully zonked
      { tct_id   :: TcId
      , tct_info :: IdBindingInfo   -- See Note [Meaning of IdBindingInfo]
      }

  | ATyVar  Name TcTyVar   -- See Note [Type variables in the type environment]

  | ATcTyCon TyCon   -- Used temporarily, during kind checking, for the
                     -- tycons and classes in this recursive group
                     -- The TyCon is always a TcTyCon.  Its kind
                     -- can be a mono-kind or a poly-kind; in TcTyClsDcls see
                     -- Note [Type checking recursive type and class declarations]

  | APromotionErr PromotionErr

-- | Matches on either a global 'TyCon' or a 'TcTyCon'.
tcTyThingTyCon_maybe :: TcTyThing -> Maybe TyCon
tcTyThingTyCon_maybe (AGlobal (ATyCon tc)) = Just tc
tcTyThingTyCon_maybe (ATcTyCon tc_tc)      = Just tc_tc
tcTyThingTyCon_maybe _                     = Nothing

instance Outputable TcTyThing where     -- Debugging only
   ppr (AGlobal g)      = ppr g
   ppr elt@(ATcId {})   = text "Identifier" <>
                          brackets (ppr (tct_id elt) <> dcolon
                                 <> ppr (varType (tct_id elt)) <> comma
                                 <+> ppr (tct_info elt))
   ppr (ATyVar n tv)    = text "Type variable" <+> quotes (ppr n) <+> equals <+> ppr tv
                            <+> dcolon <+> ppr (varType tv)
   ppr (ATcTyCon tc)    = text "ATcTyCon" <+> ppr tc <+> dcolon <+> ppr (tyConKind tc)
   ppr (APromotionErr err) = text "APromotionErr" <+> ppr err

-- | IdBindingInfo describes how an Id is bound.
--
-- It is used for the following purposes:
-- a) for static forms in 'GHC.Tc.Gen.Expr.checkClosedInStaticForm' and
-- b) to figure out when a nested binding can be generalised,
--    in 'GHC.Tc.Gen.Bind.decideGeneralisationPlan'.
--
data IdBindingInfo -- See Note [Meaning of IdBindingInfo]
    = NotLetBound
    | ClosedLet
    | NonClosedLet
         RhsNames        -- Used for (static e) checks only
         ClosedTypeId    -- Used for generalisation checks
                         -- and for (static e) checks

-- | IsGroupClosed describes a group of mutually-recursive bindings
data IsGroupClosed
  = IsGroupClosed
      (NameEnv RhsNames)  -- Free var info for the RHS of each binding in the group
                          -- Used only for (static e) checks

      ClosedTypeId        -- True <=> all the free vars of the group are
                          --          imported or ClosedLet or
                          --          NonClosedLet with ClosedTypeId=True.
                          --          In particular, no tyvars, no NotLetBound

type RhsNames = NameSet   -- Names of variables, mentioned on the RHS of
                          -- a definition, that are not Global or ClosedLet

type ClosedTypeId = Bool
  -- See Note [Meaning of IdBindingInfo]

{- Note [Meaning of IdBindingInfo]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
NotLetBound means that
  the Id is not let-bound (e.g. it is bound in a
  lambda-abstraction or in a case pattern)

ClosedLet means that
   - The Id is let-bound,
   - Any free term variables are also Global or ClosedLet
   - Its type has no free variables (NB: a top-level binding subject
     to the MR might have free vars in its type)
   These ClosedLets can definitely be floated to top level; and we
   may need to do so for static forms.

   Property:   ClosedLet
             is equivalent to
               NonClosedLet emptyNameSet True

(NonClosedLet (fvs::RhsNames) (cl::ClosedTypeId)) means that
   - The Id is let-bound

   - The fvs::RhsNames contains the free names of the RHS,
     excluding Global and ClosedLet ones.

   - For the ClosedTypeId field see Note [Bindings with closed types: ClosedTypeId]

For (static e) to be valid, we need for every 'x' free in 'e',
that x's binding is floatable to the top level.  Specifically:
   * x's RhsNames must be empty
   * x's type has no free variables
See Note [Grand plan for static forms] in "GHC.Iface.Tidy.StaticPtrTable".
This test is made in GHC.Tc.Gen.Expr.checkClosedInStaticForm.
Actually knowing x's RhsNames (rather than just its emptiness
or otherwise) is just so we can produce better error messages

Note [Bindings with closed types: ClosedTypeId]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider

  f x = let g ys = map not ys
        in ...

Can we generalise 'g' under the OutsideIn algorithm?  Yes,
because all g's free variables are top-level; that is they themselves
have no free type variables, and it is the type variables in the
environment that makes things tricky for OutsideIn generalisation.

Here's the invariant:
   If an Id has ClosedTypeId=True (in its IdBindingInfo), then
   the Id's type is /definitely/ closed (has no free type variables).
   Specifically,
       a) The Id's actual type is closed (has no free tyvars)
       b) Either the Id has a (closed) user-supplied type signature
          or all its free variables are Global/ClosedLet
             or NonClosedLet with ClosedTypeId=True.
          In particular, none are NotLetBound.

Why is (b) needed?   Consider
    \x. (x :: Int, let y = x+1 in ...)
Initially x::alpha.  If we happen to typecheck the 'let' before the
(x::Int), y's type will have a free tyvar; but if the other way round
it won't.  So we treat any let-bound variable with a free
non-let-bound variable as not ClosedTypeId, regardless of what the
free vars of its type actually are.

But if it has a signature, all is well:
   \x. ...(let { y::Int; y = x+1 } in
           let { v = y+2 } in ...)...
Here the signature on 'v' makes 'y' a ClosedTypeId, so we can
generalise 'v'.

Note that:

  * A top-level binding may not have ClosedTypeId=True, if it suffers
    from the MR

  * A nested binding may be closed (eg 'g' in the example we started
    with). Indeed, that's the point; whether a function is defined at
    top level or nested is orthogonal to the question of whether or
    not it is closed.

  * A binding may be non-closed because it mentions a lexically scoped
    *type variable*  Eg
        f :: forall a. blah
        f x = let g y = ...(y::a)...

Under OutsideIn we are free to generalise an Id all of whose free
variables have ClosedTypeId=True (or imported).  This is an extension
compared to the JFP paper on OutsideIn, which used "top-level" as a
proxy for "closed".  (It's not a good proxy anyway -- the MR can make
a top-level binding with a free type variable.)

Note [Type variables in the type environment]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The type environment has a binding for each lexically-scoped
type variable that is in scope.  For example

  f :: forall a. a -> a
  f x = (x :: a)

  g1 :: [a] -> a
  g1 (ys :: [b]) = head ys :: b

  g2 :: [Int] -> Int
  g2 (ys :: [c]) = head ys :: c

* The forall'd variable 'a' in the signature scopes over f's RHS.

* The pattern-bound type variable 'b' in 'g1' scopes over g1's
  RHS; note that it is bound to a skolem 'a' which is not itself
  lexically in scope.

* The pattern-bound type variable 'c' in 'g2' is bound to
  Int; that is, pattern-bound type variables can stand for
  arbitrary types. (see
    GHC proposal #128 "Allow ScopedTypeVariables to refer to types"
    https://github.com/ghc-proposals/ghc-proposals/pull/128,
  and the paper
    "Type variables in patterns", Haskell Symposium 2018.


This is implemented by the constructor
   ATyVar Name TcTyVar
in the type environment.

* The Name is the name of the original, lexically scoped type
  variable

* The TcTyVar is sometimes a skolem (like in 'f'), and sometimes
  a unification variable (like in 'g1', 'g2').  We never zonk the
  type environment so in the latter case it always stays as a
  unification variable, although that variable may be later
  unified with a type (such as Int in 'g2').
-}

instance Outputable IdBindingInfo where
  ppr NotLetBound = text "NotLetBound"
  ppr ClosedLet = text "TopLevelLet"
  ppr (NonClosedLet fvs closed_type) =
    text "TopLevelLet" <+> ppr fvs <+> ppr closed_type

--------------
pprTcTyThingCategory :: TcTyThing -> SDoc
pprTcTyThingCategory = text . capitalise . tcTyThingCategory

tcTyThingCategory :: TcTyThing -> String
tcTyThingCategory (AGlobal thing)    = tyThingCategory thing
tcTyThingCategory (ATyVar {})        = "type variable"
tcTyThingCategory (ATcId {})         = "local identifier"
tcTyThingCategory (ATcTyCon {})      = "local tycon"
tcTyThingCategory (APromotionErr pe) = peCategory pe

{-
************************************************************************
*                                                                      *
        Operations over ImportAvails
*                                                                      *
************************************************************************
-}


mkModDeps :: Set (UnitId, ModuleNameWithIsBoot)
          -> InstalledModuleEnv ModuleNameWithIsBoot
mkModDeps deps = S.foldl' add emptyInstalledModuleEnv deps
  where
    add env (uid, elt) = extendInstalledModuleEnv env (mkModule uid (gwib_mod elt)) elt

plusModDeps :: InstalledModuleEnv ModuleNameWithIsBoot
            -> InstalledModuleEnv ModuleNameWithIsBoot
            -> InstalledModuleEnv ModuleNameWithIsBoot
plusModDeps = plusInstalledModuleEnv plus_mod_dep
  where
    plus_mod_dep r1@(GWIB { gwib_mod = m1, gwib_isBoot = boot1 })
                 r2@(GWIB {gwib_mod = m2, gwib_isBoot = boot2})
      | assertPpr (m1 == m2) ((ppr m1 <+> ppr m2) $$ (ppr (boot1 == IsBoot) <+> ppr (boot2 == IsBoot)))
        boot1 == IsBoot = r2
      | otherwise = r1
      -- If either side can "see" a non-hi-boot interface, use that
      -- Reusing existing tuples saves 10% of allocations on test
      -- perf/compiler/MultiLayerModules

emptyImportAvails :: ImportAvails
emptyImportAvails = ImportAvails { imp_mods          = emptyModuleEnv,
                                   imp_direct_dep_mods = emptyInstalledModuleEnv,
                                   imp_dep_direct_pkgs = S.empty,
                                   imp_sig_mods      = [],
                                   imp_trust_pkgs    = S.empty,
                                   imp_trust_own_pkg = False,
                                   imp_boot_mods   = emptyInstalledModuleEnv,
                                   imp_orphs         = [],
                                   imp_finsts        = [] }

-- | Union two ImportAvails
--
-- This function is a key part of Import handling, basically
-- for each import we create a separate ImportAvails structure
-- and then union them all together with this function.
plusImportAvails ::  ImportAvails ->  ImportAvails ->  ImportAvails
plusImportAvails
  (ImportAvails { imp_mods = mods1,
                  imp_direct_dep_mods = ddmods1,
                  imp_dep_direct_pkgs = ddpkgs1,
                  imp_boot_mods = srs1,
                  imp_sig_mods = sig_mods1,
                  imp_trust_pkgs = tpkgs1, imp_trust_own_pkg = tself1,
                  imp_orphs = orphs1, imp_finsts = finsts1 })
  (ImportAvails { imp_mods = mods2,
                  imp_direct_dep_mods = ddmods2,
                  imp_dep_direct_pkgs = ddpkgs2,
                  imp_boot_mods = srcs2,
                  imp_sig_mods = sig_mods2,
                  imp_trust_pkgs = tpkgs2, imp_trust_own_pkg = tself2,
                  imp_orphs = orphs2, imp_finsts = finsts2 })
  = ImportAvails { imp_mods          = plusModuleEnv_C (++) mods1 mods2,
                   imp_direct_dep_mods = ddmods1 `plusModDeps` ddmods2,
                   imp_dep_direct_pkgs      = ddpkgs1 `S.union` ddpkgs2,
                   imp_trust_pkgs    = tpkgs1 `S.union` tpkgs2,
                   imp_trust_own_pkg = tself1 || tself2,
                   imp_boot_mods   = srs1 `plusModDeps` srcs2,
                   imp_sig_mods      = unionListsOrd sig_mods1 sig_mods2,
                   imp_orphs         = unionListsOrd orphs1 orphs2,
                   imp_finsts        = unionListsOrd finsts1 finsts2 }

{-
************************************************************************
*                                                                      *
\subsection{Where from}
*                                                                      *
************************************************************************

The @WhereFrom@ type controls where the renamer looks for an interface file
-}

data WhereFrom
  = ImportByUser IsBootInterface        -- Ordinary user import (perhaps {-# SOURCE #-})
  | ImportBySystem                      -- Non user import.
  | ImportByPlugin                      -- Importing a plugin;
                                        -- See Note [Care with plugin imports] in GHC.Iface.Load

instance Outputable WhereFrom where
  ppr (ImportByUser IsBoot)                = text "{- SOURCE -}"
  ppr (ImportByUser NotBoot)               = empty
  ppr ImportBySystem                       = text "{- SYSTEM -}"
  ppr ImportByPlugin                       = text "{- PLUGIN -}"


{- *********************************************************************
*                                                                      *
                Type signatures
*                                                                      *
********************************************************************* -}

-- These data types need to be here only because
-- GHC.Tc.Solver uses them, and GHC.Tc.Solver is fairly
-- low down in the module hierarchy

type TcSigFun  = Name -> Maybe TcSigInfo

data TcSigInfo = TcIdSig     TcIdSigInfo
               | TcPatSynSig TcPatSynInfo

data TcIdSigInfo   -- See Note [Complete and partial type signatures]
  = CompleteSig    -- A complete signature with no wildcards,
                   -- so the complete polymorphic type is known.
      { sig_bndr :: TcId          -- The polymorphic Id with that type

      , sig_ctxt :: UserTypeCtxt  -- In the case of type-class default methods,
                                  -- the Name in the FunSigCtxt is not the same
                                  -- as the TcId; the former is 'op', while the
                                  -- latter is '$dmop' or some such

      , sig_loc  :: SrcSpan       -- Location of the type signature
      }

  | PartialSig     -- A partial type signature (i.e. includes one or more
                   -- wildcards). In this case it doesn't make sense to give
                   -- the polymorphic Id, because we are going to /infer/ its
                   -- type, so we can't make the polymorphic Id ab-initio
      { psig_name  :: Name   -- Name of the function; used when report wildcards
      , psig_hs_ty :: LHsSigWcType GhcRn  -- The original partial signature in
                                          -- HsSyn form
      , sig_ctxt   :: UserTypeCtxt
      , sig_loc    :: SrcSpan            -- Location of the type signature
      }


{- Note [Complete and partial type signatures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A type signature is partial when it contains one or more wildcards
(= type holes).  The wildcard can either be:
* A (type) wildcard occurring in sig_theta or sig_tau. These are
  stored in sig_wcs.
      f :: Bool -> _
      g :: Eq _a => _a -> _a -> Bool
* Or an extra-constraints wildcard, stored in sig_cts:
      h :: (Num a, _) => a -> a

A type signature is a complete type signature when there are no
wildcards in the type signature, i.e. iff sig_wcs is empty and
sig_extra_cts is Nothing.
-}

data TcIdSigInst
  = TISI { sig_inst_sig :: TcIdSigInfo

         , sig_inst_skols :: [(Name, InvisTVBinder)]
               -- Instantiated type and kind variables, TyVarTvs
               -- The Name is the Name that the renamer chose;
               --   but the TcTyVar may come from instantiating
               --   the type and hence have a different unique.
               -- No need to keep track of whether they are truly lexically
               --   scoped because the renamer has named them uniquely
               -- See Note [Binding scoped type variables] in GHC.Tc.Gen.Sig
               --
               -- NB: The order of sig_inst_skols is irrelevant
               --     for a CompleteSig, but for a PartialSig see
               --     Note [Quantified variables in partial type signatures]

         , sig_inst_theta  :: TcThetaType
               -- Instantiated theta.  In the case of a
               -- PartialSig, sig_theta does not include
               -- the extra-constraints wildcard

         , sig_inst_tau :: TcSigmaType   -- Instantiated tau
               -- See Note [sig_inst_tau may be polymorphic]

         -- Relevant for partial signature only
         , sig_inst_wcs   :: [(Name, TcTyVar)]
               -- Like sig_inst_skols, but for /named/ wildcards (_a etc).
               -- The named wildcards scope over the binding, and hence
               -- their Names may appear in type signatures in the binding

         , sig_inst_wcx   :: Maybe TcType
               -- Extra-constraints wildcard to fill in, if any
               -- If this exists, it is surely of the form (meta_tv |> co)
               -- (where the co might be reflexive). This is filled in
               -- only from the return value of GHC.Tc.Gen.HsType.tcAnonWildCardOcc
         }

{- Note [sig_inst_tau may be polymorphic]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Note that "sig_inst_tau" might actually be a polymorphic type,
if the original function had a signature like
   forall a. Eq a => forall b. Ord b => ....
But that's ok: tcMatchesFun (called by tcRhs) can deal with that
It happens, too!  See Note [Polymorphic methods] in GHC.Tc.TyCl.Class.

Note [Quantified variables in partial type signatures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   f :: forall a b. _ -> a -> _ -> b
   f (x,y) p q = q

Then we expect f's final type to be
  f :: forall {x,y}. forall a b. (x,y) -> a -> b -> b

Note that x,y are Inferred, and can't be use for visible type
application (VTA).  But a,b are Specified, and remain Specified
in the final type, so we can use VTA for them.  (Exception: if
it turns out that a's kind mentions b we need to reorder them
with scopedSort.)

The sig_inst_skols of the TISI from a partial signature records
that original order, and is used to get the variables of f's
final type in the correct order.


Note [Wildcards in partial signatures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The wildcards in psig_wcs may stand for a type mentioning
the universally-quantified tyvars of psig_ty

E.g.  f :: forall a. _ -> a
      f x = x
We get sig_inst_skols = [a]
       sig_inst_tau   = _22 -> a
       sig_inst_wcs   = [_22]
and _22 in the end is unified with the type 'a'

Moreover the kind of a wildcard in sig_inst_wcs may mention
the universally-quantified tyvars sig_inst_skols
e.g.   f :: t a -> t _
Here we get
   sig_inst_skols = [k:*, (t::k ->*), (a::k)]
   sig_inst_tau   = t a -> t _22
   sig_inst_wcs   = [ _22::k ]
-}

data TcPatSynInfo
  = TPSI {
        patsig_name           :: Name,
        patsig_implicit_bndrs :: [InvisTVBinder], -- Implicitly-bound kind vars (Inferred) and
                                                  -- implicitly-bound type vars (Specified)
          -- See Note [The pattern-synonym signature splitting rule] in GHC.Tc.TyCl.PatSyn
        patsig_univ_bndrs     :: [InvisTVBinder], -- Bound by explicit user forall
        patsig_req            :: TcThetaType,
        patsig_ex_bndrs       :: [InvisTVBinder], -- Bound by explicit user forall
        patsig_prov           :: TcThetaType,
        patsig_body_ty        :: TcSigmaType
    }

instance Outputable TcSigInfo where
  ppr (TcIdSig     idsi) = ppr idsi
  ppr (TcPatSynSig tpsi) = text "TcPatSynInfo" <+> ppr tpsi

instance Outputable TcIdSigInfo where
    ppr (CompleteSig { sig_bndr = bndr })
        = ppr bndr <+> dcolon <+> ppr (idType bndr)
    ppr (PartialSig { psig_name = name, psig_hs_ty = hs_ty })
        = text "[partial signature]" <+> ppr name <+> dcolon <+> ppr hs_ty

instance Outputable TcIdSigInst where
    ppr (TISI { sig_inst_sig = sig, sig_inst_skols = skols
              , sig_inst_theta = theta, sig_inst_tau = tau })
        = hang (ppr sig) 2 (vcat [ ppr skols, ppr theta <+> darrow <+> ppr tau ])

instance Outputable TcPatSynInfo where
    ppr (TPSI{ patsig_name = name}) = ppr name

isPartialSig :: TcIdSigInst -> Bool
isPartialSig (TISI { sig_inst_sig = PartialSig {} }) = True
isPartialSig _                                       = False

-- | No signature or a partial signature
hasCompleteSig :: TcSigFun -> Name -> Bool
hasCompleteSig sig_fn name
  = case sig_fn name of
      Just (TcIdSig (CompleteSig {})) -> True
      _                               -> False


{-
Constraint Solver Plugins
-------------------------
-}

-- | The @solve@ function of a type-checking plugin takes in Given
-- and Wanted constraints, and should return a 'TcPluginSolveResult'
-- indicating which Wanted constraints it could solve, or whether any are
-- insoluble.
type TcPluginSolver = EvBindsVar
                   -> [Ct] -- ^ Givens
                   -> [Ct] -- ^ Wanteds
                   -> TcPluginM TcPluginSolveResult

-- | For rewriting type family applications, a type-checking plugin provides
-- a function of this type for each type family 'TyCon'.
--
-- The function is provided with the current set of Given constraints, together
-- with the arguments to the type family.
-- The type family application will always be fully saturated.
type TcPluginRewriter
  =  RewriteEnv -- ^ Rewriter environment
  -> [Ct]       -- ^ Givens
  -> [TcType]   -- ^ type family arguments
  -> TcPluginM TcPluginRewriteResult

-- | 'TcPluginM' is the monad in which type-checking plugins operate.
newtype TcPluginM a = TcPluginM { runTcPluginM :: TcM a }
  deriving newtype (Functor, Applicative, Monad, MonadFail)

-- | This function provides an escape for direct access to
-- the 'TcM` monad.  It should not be used lightly, and
-- the provided 'TcPluginM' API should be favoured instead.
unsafeTcPluginTcM :: TcM a -> TcPluginM a
unsafeTcPluginTcM = TcPluginM

data TcPlugin = forall s. TcPlugin
  { tcPluginInit :: TcPluginM s
    -- ^ Initialize plugin, when entering type-checker.

  , tcPluginSolve :: s -> TcPluginSolver
    -- ^ Solve some constraints.
    --
    -- This function will be invoked at two points in the constraint solving
    -- process: once to simplify Given constraints, and once to solve
    -- Wanted constraints. In the first case (and only in the first case),
    -- no Wanted constraints will be passed to the plugin.
    --
    -- The plugin can either return a contradiction,
    -- or specify that it has solved some constraints (with evidence),
    -- and possibly emit additional constraints. These returned constraints
    -- must be Givens in the first case, and Wanteds in the second.
    --
    -- Use @ \\ _ _ _ _ -> pure $ TcPluginOk [] [] @ if your plugin
    -- does not provide this functionality.

  , tcPluginRewrite :: s -> UniqFM TyCon TcPluginRewriter
    -- ^ Rewrite saturated type family applications.
    --
    -- The plugin is expected to supply a mapping from type family names to
    -- rewriting functions. For each type family 'TyCon', the plugin should
    -- provide a function which takes in the given constraints and arguments
    -- of a saturated type family application, and return a possible rewriting.
    -- See 'TcPluginRewriter' for the expected shape of such a function.
    --
    -- Use @ \\ _ -> emptyUFM @ if your plugin does not provide this functionality.

  , tcPluginStop :: s -> TcPluginM ()
   -- ^ Clean up after the plugin, when exiting the type-checker.
  }

-- | The plugin found a contradiction.
-- The returned constraints are removed from the inert set,
-- and recorded as insoluble.
--
-- The returned list of constraints should never be empty.
pattern TcPluginContradiction :: [Ct] -> TcPluginSolveResult
pattern TcPluginContradiction insols
  = TcPluginSolveResult
  { tcPluginInsolubleCts = insols
  , tcPluginSolvedCts    = []
  , tcPluginNewCts       = [] }

-- | The plugin has not found any contradictions,
--
-- The first field is for constraints that were solved.
-- The second field contains new work, that should be processed by
-- the constraint solver.
pattern TcPluginOk :: [(EvTerm, Ct)] -> [Ct] -> TcPluginSolveResult
pattern TcPluginOk solved new
  = TcPluginSolveResult
  { tcPluginInsolubleCts = []
  , tcPluginSolvedCts    = solved
  , tcPluginNewCts       = new }

-- | Result of running a solver plugin.
data TcPluginSolveResult
  = TcPluginSolveResult
  { -- | Insoluble constraints found by the plugin.
    --
    -- These constraints will be added to the inert set,
    -- and reported as insoluble to the user.
    tcPluginInsolubleCts :: [Ct]
    -- | Solved constraints, together with their evidence.
    --
    -- These are removed from the inert set, and the
    -- evidence for them is recorded.
  , tcPluginSolvedCts :: [(EvTerm, Ct)]
    -- | New constraints that the plugin wishes to emit.
    --
    -- These will be added to the work list.
  , tcPluginNewCts :: [Ct]
  }

data TcPluginRewriteResult
  =
  -- | The plugin does not rewrite the type family application.
    TcPluginNoRewrite

  -- | The plugin rewrites the type family application
  -- providing a rewriting together with evidence: a 'Reduction',
  -- which contains the rewritten type together with a 'Coercion'
  -- whose right-hand-side type is the rewritten type.
  --
  -- The plugin can also emit additional Wanted constraints.
  | TcPluginRewriteTo
    { tcPluginReduction    :: !Reduction
    , tcRewriterNewWanteds :: [Ct]
    }

-- | A collection of candidate default types for a type variable.
data DefaultingProposal
  = DefaultingProposal
    { deProposalTyVar :: TcTyVar
      -- ^ The type variable to default.
    , deProposalCandidates :: [Type]
      -- ^ Candidate types to default the type variable to.
    , deProposalCts :: [Ct]
      -- ^ The constraints against which defaults are checked.
    }

instance Outputable DefaultingProposal where
  ppr p = text "DefaultingProposal"
          <+> ppr (deProposalTyVar p)
          <+> ppr (deProposalCandidates p)
          <+> ppr (deProposalCts p)

type DefaultingPluginResult = [DefaultingProposal]
type FillDefaulting = WantedConstraints -> TcPluginM DefaultingPluginResult

-- | A plugin for controlling defaulting.
data DefaultingPlugin = forall s. DefaultingPlugin
  { dePluginInit :: TcPluginM s
    -- ^ Initialize plugin, when entering type-checker.
  , dePluginRun :: s -> FillDefaulting
    -- ^ Default some types
  , dePluginStop :: s -> TcPluginM ()
   -- ^ Clean up after the plugin, when exiting the type-checker.
  }

{- *********************************************************************
*                                                                      *
                        Role annotations
*                                                                      *
********************************************************************* -}

type RoleAnnotEnv = NameEnv (LRoleAnnotDecl GhcRn)

mkRoleAnnotEnv :: [LRoleAnnotDecl GhcRn] -> RoleAnnotEnv
mkRoleAnnotEnv role_annot_decls
 = mkNameEnv [ (name, ra_decl)
             | ra_decl <- role_annot_decls
             , let name = roleAnnotDeclName (unLoc ra_decl)
             , not (isUnboundName name) ]
       -- Some of the role annots will be unbound;
       -- we don't wish to include these

emptyRoleAnnotEnv :: RoleAnnotEnv
emptyRoleAnnotEnv = emptyNameEnv

lookupRoleAnnot :: RoleAnnotEnv -> Name -> Maybe (LRoleAnnotDecl GhcRn)
lookupRoleAnnot = lookupNameEnv

getRoleAnnots :: [Name] -> RoleAnnotEnv -> [LRoleAnnotDecl GhcRn]
getRoleAnnots bndrs role_env
  = mapMaybe (lookupRoleAnnot role_env) bndrs

{- *********************************************************************
*                                                                      *
                  Linting a TcGblEnv
*                                                                      *
********************************************************************* -}

-- | Check the 'TcGblEnv' for consistency. Currently, only checks
-- axioms, but should check other aspects, too.
lintGblEnv :: Logger -> DynFlags -> TcGblEnv -> TcM ()
lintGblEnv logger dflags tcg_env =
  -- TODO empty list means no extra in scope from GHCi, is this correct?
  liftIO $ lintAxioms logger (initLintConfig dflags []) (text "TcGblEnv axioms") axioms
  where
    axioms = typeEnvCoAxioms (tcg_type_env tcg_env)

-- | This is a mirror of Template Haskell's DocLoc, but the TH names are
-- resolved to GHC names.
data DocLoc = DeclDoc Name
            | ArgDoc Name Int
            | InstDoc Name
            | ModuleDoc
  deriving (Eq, Ord)

-- | The current collection of docs that Template Haskell has built up via
-- putDoc.
type THDocs = Map DocLoc (HsDoc GhcRn)
