-- Runs at image build after the restart that applies 'max online engines'.
-- In threaded kernel mode the engine count is the default pool's thread count
-- ('number of engines at startup' isn't supported).
alter thread pool syb_default_pool with thread count = 4
go
