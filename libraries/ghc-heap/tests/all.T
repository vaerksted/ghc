setTestOpts(js_skip) # ghc-heap not supported by the JS backend

test('heap_all',
     [when(have_profiling(), extra_ways(['prof'])),
      # These ways produce slightly different heap representations.
      # Currently we don't test them.
      omit_ways(['ghci', 'hpc',
                 'nonmoving', 'nonmoving_thr', 'nonmoving_thr_ghc',
                 'nonmoving_thr_sanity']),
      # The debug RTS initializes some fields with 0xaa and so
      # this test spuriously fails.
      when(compiler_debugged(), skip)
     ],
     compile_and_run, [''])

test('heap_weak',
     [when(have_profiling(), extra_ways(['prof'])),
      # These ways produce slightly different heap representations.
      # Currently we don't test them.
      omit_ways(['ghci', 'hpc'])
     ],
     compile_and_run, [''])

# Test everything except FUNs and PAPs in all ways.
test('closure_size',
     [extra_files(['ClosureSizeUtils.hs']),
      when(have_profiling(), extra_ways(['prof'])),
      # These ways produce slightly different heap representations.
      # Currently we don't test them.
      omit_ways(['hpc'])
     ],
     compile_and_run, [''])

# Test PAPs and FUNs only in normal way (e.g. with -O0)
# since otherwise the simplifier interferes.
test('closure_size_noopt',
     [extra_files(['ClosureSizeUtils.hs']),
      only_ways(['normal'])
     ],
     compile_and_run, [''])

test('tso_and_stack_closures',
     [extra_files(['create_tso.c','create_tso.h','TestUtils.hs']),
      only_ways(['profthreaded']),
      ignore_stdout,
      ignore_stderr
     ],
     multi_compile_and_run, ['tso_and_stack_closures', [('create_tso.c','')], ''])

test('parse_tso_flags',
     [extra_files(['TestUtils.hs']),
      only_ways(['normal']),
      ignore_stdout,
      ignore_stderr
     ],
     compile_and_run, [''])
test('T21622',
     only_ways(['normal']),
     compile_and_run, [''])
