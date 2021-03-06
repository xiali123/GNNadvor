// <primitive>_app.cuh includes
#include <gunrock/app/app.cuh>

// single-source shortest path includes
#include <gunrock/app/spmm/spmm_enactor.cuh>
#include <gunrock/app/spmm/spmm_test.cuh>

namespace gunrock {
namespace app {
namespace spmm {

cudaError_t UseParameters(util::Parameters &parameters) {
  cudaError_t retval = cudaSuccess;
  GUARD_CU(UseParameters_app(parameters));
  GUARD_CU(UseParameters_problem(parameters));
  GUARD_CU(UseParameters_enactor(parameters));

  GUARD_CU(parameters.Use<int>(
      "feature-len",
      util::REQUIRED_ARGUMENT | util::SINGLE_VALUE | util::OPTIONAL_PARAMETER,
      128, "feature length", __FILE__, __LINE__));

  return retval;
}

/**
 * @brief Run spmm tests
 * @tparam     GraphT        Type of the graph
 * @tparam     ValueT        Type of the distances
 * @param[in]  parameters    Excution parameters
 * @param[in]  graph         Input graph
 * @param[in]  ref_distances Reference distances
 * @param[in]  target        Whether to perform the spmm
 * \return cudaError_t error message(s), if any
 */
template <typename GraphT, typename ValueT = typename GraphT::ValueT>
cudaError_t RunTests(util::Parameters &parameters, GraphT &graph,
                    //  ValueT **ref_distances = NULL,
                     util::Location target = util::DEVICE) {
  cudaError_t retval = cudaSuccess;
  typedef typename GraphT::VertexT VertexT;
  typedef typename GraphT::SizeT SizeT;
  typedef Problem<GraphT> ProblemT;
  typedef Enactor<ProblemT> EnactorT;
  util::CpuTimer cpu_timer, total_timer;
  cpu_timer.Start();
  total_timer.Start();

  // parse configurations from parameters
  bool quiet_mode = parameters.Get<bool>("quiet");
  
  int num_runs = parameters.Get<int>("num-runs");
  std::string validation = parameters.Get<std::string>("validation");
  int feature_len = parameters.Get<int>("feature-len");

  util::Info info("spmm", parameters, graph);  // initialize Info structure

  // Allocate host-side array (for both reference and GPU-computed results)
  
  // Allocate problem and enactor on GPU, and initialize them
  ProblemT problem(parameters);
  EnactorT enactor;
  GUARD_CU(problem.Init(graph, target));
  GUARD_CU(enactor.Init(problem, target));
  ValueT *h_output = new ValueT[((uint64_t)graph.nodes) *
                                  feature_len];
  cpu_timer.Stop();
  parameters.Set("preprocess-time", cpu_timer.ElapsedMillis());

  // perform spmm
  // VertexT src;
  for (int run_num = 0; run_num < num_runs; ++run_num) {
    // src = srcs[run_num % num_srcs];
    GUARD_CU(problem.Reset(target));
    GUARD_CU(enactor.Reset(target));
    if (run_num == num_runs - 1)
      util::PrintMsg("__________________________", !quiet_mode);

    cpu_timer.Start();
    GUARD_CU(enactor.Enact());
    cpu_timer.Stop();
    info.CollectSingleRun(cpu_timer.ElapsedMillis());

    if (run_num == num_runs - 1)
      util::PrintMsg(
        "--------------------------\nRun " + std::to_string(run_num) +
            " elapsed: " +
            std::to_string(cpu_timer.ElapsedMillis())
            //+ " ms, src = "+ std::to_string(src)
            + " ms, #iterations = " +
            std::to_string(enactor.enactor_slices[0].enactor_stats.iteration) + "\n=======================\n\n",
        !quiet_mode);
    if (validation == "each") {
      GUARD_CU(problem.Extract(h_output));
      /*TODO: host test gets segfault. debug*/
      // SizeT num_errors = app::spmm::Validate_Results(
      //     parameters, graph, h_output,
      //     feature_len, true);
    }
  }

  cpu_timer.Start();
  
  GUARD_CU(problem.Extract(h_output));
  if (validation == "last") {
    /*TODO: host test gets segfault. debug*/
    // SizeT num_errors = app::spmm::Validate_Results(
    //     parameters, graph, h_output,
    //     feature_len, true);
  }
  
#ifdef ENABLE_PERFORMANCE_PROFILING
  // Display_Performance_Profiling(enactor);
#endif

  // Clean up
  GUARD_CU(enactor.Release(target));
  GUARD_CU(problem.Release(target));
  delete[] h_output;
  h_output = NULL;
  cpu_timer.Stop();
  total_timer.Stop();

  // info.Finalize(cpu_timer.ElapsedMillis(), total_timer.ElapsedMillis());
  return retval;
}

}  // namespace spmm
}  // namespace app
}  // namespace gunrock

/*
 * @brief Entry of gunrock_spmm function
 * @tparam     GraphT     Type of the graph
 * @tparam     ValueT     Type of the distances
 * @param[in]  parameters Excution parameters
 * @param[in]  graph      Input graph
 * @param[out] distances  Return shortest distance to source per vertex
 * @param[out] preds      Return predecessors of each vertex
 * \return     double     Return accumulated elapsed times for all runs
 */
template <typename GraphT, typename ValueT = typename GraphT::ValueT>
double gunrock_spmm(gunrock::util::Parameters &parameters, GraphT &graph,
                    ValueT **distances,
                    typename GraphT::VertexT **preds = NULL) {
  typedef typename GraphT::VertexT VertexT;
  typedef gunrock::app::spmm::Problem<GraphT> ProblemT;
  typedef gunrock::app::spmm::Enactor<ProblemT> EnactorT;
  gunrock::util::CpuTimer cpu_timer;
  gunrock::util::Location target = gunrock::util::DEVICE;
  double total_time = 0;
  if (parameters.UseDefault("quiet")) parameters.Set("quiet", true);

  // Allocate problem and enactor on GPU, and initialize them
  ProblemT problem(parameters);
  EnactorT enactor;
  problem.Init(graph, target);
  enactor.Init(problem, target);
  
  int num_runs = parameters.Get<int>("num-runs");
  int feature_len = parameters.Get<int>("feature-len");
  // int num_srcs = srcs.size();
  for (int run_num = 0; run_num < num_runs; ++run_num) {
    // int src_num = run_num % num_srcs;
    // VertexT src = srcs[src_num];
    problem.Reset(target);
    // enactor.Reset(target);
    cpu_timer.Start();
    
    enactor.Enact();
    enactor.Enact();

    cpu_timer.Stop();

    total_time += cpu_timer.ElapsedMillis();
    problem.Extract();
  }

  enactor.Release(target);
  problem.Release(target);
  // srcs.clear();
  return total_time;
}

/*
 * @brief Simple interface take in graph as CSR format
 * @param[in]  num_nodes   Number of veritces in the input graph
 * @param[in]  num_edges   Number of edges in the input graph
 * @param[in]  row_offsets CSR-formatted graph input row offsets
 * @param[in]  col_indices CSR-formatted graph input column indices
 * @param[in]  edge_values CSR-formatted graph input edge weights
 * @param[in]  num_runs    Number of runs to perform spmm
 * @param[in]  sources     Sources to begin traverse, one for each run
 * @param[in]  mark_preds  Whether to output predecessor info
 * @param[out] distances   Return shortest distance to source per vertex
 * @param[out] preds       Return predecessors of each vertex
 * \return     double      Return accumulated elapsed times for all runs
 */
template <typename VertexT = int, typename SizeT = int,
          typename GValueT = unsigned int, typename spmmValueT = GValueT>
double spmm(const SizeT num_nodes, const SizeT num_edges,
            const SizeT *row_offsets, const VertexT *col_indices,
            const GValueT *edge_values, const int num_runs
            // VertexT *sources,
            // const bool mark_pred, spmmValueT **distances,
            // VertexT **preds = NULL
            ) {
  typedef typename gunrock::app::TestGraph<VertexT, SizeT, GValueT,
                                           gunrock::graph::HAS_EDGE_VALUES |
                                               gunrock::graph::HAS_CSR>
      GraphT;
  typedef typename GraphT::CsrT CsrT;

  // Setup parameters
  gunrock::util::Parameters parameters("spmm");
  gunrock::graphio::UseParameters(parameters);
  gunrock::app::spmm::UseParameters(parameters);
  gunrock::app::UseParameters_test(parameters);
  parameters.Parse_CommandLine(0, NULL);
  parameters.Set("graph-type", "by-pass");
  // parameters.Set("mark-pred", mark_pred);
  parameters.Set("num-runs", num_runs);
  // std::vector<VertexT> srcs;
  // for (int i = 0; i < num_runs; i++) srcs.push_back(sources[i]);
  // parameters.Set("srcs", srcs);

  bool quiet = parameters.Get<bool>("quiet");
  GraphT graph;
  // Assign pointers into gunrock graph format
  graph.CsrT::Allocate(num_nodes, num_edges, gunrock::util::HOST);
  graph.CsrT::row_offsets.SetPointer((SizeT *)row_offsets, num_nodes + 1,
                                     gunrock::util::HOST);
  graph.CsrT::column_indices.SetPointer((VertexT *)col_indices, num_edges,
                                        gunrock::util::HOST);
  graph.CsrT::edge_values.SetPointer((GValueT *)edge_values, num_edges,
                                     gunrock::util::HOST);
  gunrock::graphio::LoadGraph(parameters, graph);

  // Run the spmm
  double elapsed_time = gunrock_spmm(parameters, graph);

  // Cleanup
  graph.Release();
  // srcs.clear();

  return elapsed_time;
}

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
