-- Runs once at image build, right after the installer configures the server.
-- Creates the test database that data-diff's tests connect to.
use master
go
disk init name = 'testdata', physname = '/opt/sap/data/testdata.dat', size = '250M'
go
disk init name = 'testlog', physname = '/opt/sap/data/testlog.dat', size = '50M'
go
create database testdb on testdata = '250M' log on testlog = '50M'
go
exec sp_dboption testdb, 'select into/bulkcopy/pllsort', true
go
exec sp_dboption testdb, 'trunc log on chkpt', true
go
use testdb
go
checkpoint
go
