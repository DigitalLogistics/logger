{ cabal, blazeBuilder, conduit, exceptions, fastLogger, liftedBase
, monadControl, monadLoops, mtl, resourcet, stm, stmChans, text
, transformers, transformersBase, conduitExtra
}:

cabal.mkDerivation (self: {
  pname = "monad-logger-new";
  version = "0.4";
  src = ./.;
  buildDepends = [
    blazeBuilder conduit exceptions fastLogger liftedBase monadControl monadLoops
    mtl resourcet stm stmChans text transformers transformersBase conduitExtra
  ];
  meta = {
    homepage = "https://github.com/kazu-yamamoto/logger";
    description = "A class of monads which can log messages";
    license = self.stdenv.lib.licenses.mit;
    platforms = self.ghc.meta.platforms;
  };
})
