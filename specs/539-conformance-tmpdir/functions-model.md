# Changed functions

- newTmpDirOwner: IO TmpDirOwner; allocated once per executable process.
- bracketTmpDir: TmpDirOwner -> IO a -> IO a; reject an occupied owner;
  preserve result/exception and release its environment and files on exit.
- runRows: TmpDirOwner -> [String] -> FilePath -> IO (); unchanged row behavior.
- runForkProbe: TmpDirOwner -> IO (); unchanged probe behavior.
