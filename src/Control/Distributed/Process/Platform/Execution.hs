-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Execution
-- Copyright   :  (c) Tim Watson 2013 - 2014
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- [Inter-Process Traffic Management]
--
-- The /Execution Framework/ provides tools for load regulation, workload
-- shedding and remote hand-off. The currently implementation provides only
-- a subset of the plumbing required, comprising tools for event management,
-- mailbox buffering and message routing.
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Execution
  ( -- * Mailbox Buffering
    module Control.Distributed.Process.Platform.Execution.Mailbox
    -- * Message Exchanges
  , module Control.Distributed.Process.Platform.Execution.Exchange
  ) where

import Control.Distributed.Process.Platform.Execution.Exchange hiding (startSupervised)
import Control.Distributed.Process.Platform.Execution.Mailbox hiding (startSupervised, post)

{-

Load regulation requires that we apply limits to various parts of the system.
The manner in which they're applied may vary, but the mechanisms are limited
to:

1. rejecting the activity/request
2. accepting the activity immediately
3. blocking some or all requestors
4. blocking some (or all) activities
5. terminiating some (or all) activities

-}


