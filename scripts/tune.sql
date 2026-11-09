-- Runs at image build, after post-install.sql. Sizes the server for parallel
-- test runs inside a 2 GB container. Everything here is dynamic except
-- 'max online engines', which takes effect after the restart that follows;
-- tune-after-restart.sql then raises the engine thread count.
use master
go
exec sp_configure 'max memory', 786432                 -- 1.5 GB, in 2k pages
go
exec sp_configure 'number of user connections', 100
go
exec sp_configure 'number of locks', 200000
go
exec sp_configure 'number of open objects', 2000
go
exec sp_configure 'number of open indexes', 2000
go
exec sp_configure 'procedure cache size', 51200        -- 100 MB, in 2k pages
go
exec sp_cacheconfig 'default data cache', '768M'
go
exec sp_configure 'max online engines', 4               -- static
go
-- tempdb: joindiff and sorts need more than the installer's 100 MB
disk init name = 'tempdbdev2', physname = '/opt/sap/data/tempdbdev2.dat', size = '1000M'
go
alter database tempdb on tempdbdev2 = '1000M'
go
