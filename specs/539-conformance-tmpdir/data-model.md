# Owned data

TmpDirOwner is an opaque, explicitly allocated exclusive-use capability shared
by every session of one executable. It holds occupancy, not product state.
One active lifetime holds the exact previous optional TMPDIR and its fresh path.
These values never change the product receipt schema.
