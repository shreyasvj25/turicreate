#ifndef MPS_MODULE_H_
#define MPS_MODULE_H_

#include <assert.h>
#include <map>
#include <vector>

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#import "mps_networks.h"
#import "mps_updater.h"

namespace turi {
namespace mps {

class MPSCNNModule {
public:
  MPSCNNModule();
  ~MPSCNNModule();
  void Init(int network_id, int n, int c_in, int h_in, int w_in, int c_out,
            int h_out, int w_out, int updater_id, const FloatArrayMap &config);
  void Forward(void *_Nonnull ptr, int64_t sz, int64_t *_Nonnull shape, int dim,
               float *_Nonnull out, bool is_train = true);
  void Backward(void *_Nonnull ptr, size_t sz, int64_t *_Nonnull shape, int dim,
                float *_Nonnull out);
  void ForwardBackward(void *_Nonnull ptr, size_t sz, int64_t *_Nonnull shape, int dim,
                       void *_Nonnull label_ptr, size_t label_sz, int64_t *_Nonnull label_shape, int label_dim,
                       void *_Nonnull weight_ptr, size_t weight_sz, int64_t *_Nonnull weight_shape, int weight_dim,
                       bool loss_image_required,
                       float *_Nonnull out);
  void Forward(void *_Nonnull ptr, size_t sz, int64_t *_Nonnull shape, int dim,
               void *_Nonnull label_ptr, size_t label_sz, int64_t *_Nonnull label_shape, int label_dim,
               void *_Nonnull weight_ptr, size_t weight_sz, int64_t *_Nonnull weight_shape, int weight_dim,
               bool loss_image_required, bool is_train,
               float *_Nonnull out);
  void Loss(void *_Nonnull ptr, size_t sz, int64_t *_Nonnull shape, int dim,
            void *_Nonnull label_ptr, size_t label_sz, int64_t *_Nonnull label_shape, int label_dim,
            void *_Nonnull weight_ptr, size_t weight_sz, int64_t *_Nonnull weight_shape, int weight_dim,
            bool loss_image_required,
            float *_Nonnull out);
  void BeginForwardBatch(
      int batch_id, void *ptr, size_t sz, int64_t *shape, int dim,
      void *label_ptr, size_t label_sz, int64_t *label_shape, int label_dim,
      void *weight_ptr, size_t weight_sz, int64_t *weight_shape, int weight_dim,
      bool loss_image_required, bool is_train);
  void BeginForwardBackwardBatch(
      int batch_id, void *ptr, size_t sz, int64_t *shape, int dim,
      void *label_ptr, size_t label_sz, int64_t *label_shape, int label_dim,
      void *weight_ptr, size_t weight_sz, int64_t *weight_shape, int weight_dim,
      bool loss_image_required);
  void WaitForBatch(int batch_id, float *forward_out, float *loss_out);
  void GetLossImages(float *_Nonnull out);
  void Update();
  void GpuUpdate();
  void Load(const FloatArrayMap &weights);
  void Export();
  void SetLearningRate(float new_lr) {
    if (updater_ != nil) {
      updater_->SetLearningRate(new_lr);
    }
  }
  int NumParams();
  MPSImageBatch *_Nonnull ExtractLossImages(MPSCNNLossLabelsBatch *_Nonnull labels, int batch_size,
                                            id<MTLCommandBuffer> cb);


  std::unordered_map<std::string,
                     std::tuple<std::string, float *, int, std::vector<int>>>
      table_;

private:
  // Used by the asynchronous API.
  struct Batch {
    id<MTLCommandBuffer> _Nullable command_buffer = nil;
    MPSImageBatch * _Nonnull input = nil;
    MPSImageBatch * _Nonnull output = nil;
    MPSImageBatch * _Nonnull top_grad = nil;
    MPSImageBatch * _Nullable loss_images = nil;
  };

  id<MTLDevice> _Nonnull dev_;
  id<MTLCommandQueue> _Nonnull cmd_queue_;
  MPSImageDescriptor *_Nonnull input_desc_ = nil;
  MPSImageDescriptor *_Nonnull output_desc_ = nil;
  MPSImageBatch *_Nonnull input_;
  MPSImageBatch *_Nonnull output_;
  MPSImageBatch *_Nonnull top_grad_;
  MPSImageBatch *_Nullable loss_images_{nil};
  MPSNetwork *_Nonnull network_{nil};
  MPSUpdater *_Nonnull updater_{nil};
  int output_chn_;
  int output_width_;

  // Used by the asynchronous API.
  std::map<int, Batch> active_batches_;  // Keyed by batch ID
  std::vector<Batch> free_batches_;

private:
  Batch* StartBatch(int batch_id);  // Throws if ID is already in use

  void SetupUpdater(int updater_id);
  void Blob2MPSImage(float *_Nonnull ptr, MPSImageBatch *_Nonnull batch);
  void MPSImage2Blob(float *_Nonnull ptr, MPSImageBatch *_Nonnull batch);
  MPSCNNLossLabelsBatch *_Nonnull initLossLabelsBatch(
      id<MTLDevice> _Nonnull device, float *_Nonnull labels_ptr, float *_Nonnull weights_ptr,
      int batch_size, int seq_len, int num_classes);
    
  void TrainingWithLoss(
      Batch *batch, void *ptr, size_t sz, int64_t *shape, int dim,
      void *label_ptr, size_t label_sz, int64_t *label_shape, int label_dim,
      void *weight_ptr, size_t weight_sz, int64_t *weight_shape, int weight_dim,
      bool loss_image_required, bool wait_until_completed, float *out,
      bool do_backward, bool is_train = true);
};

}  // namespace mps
}  // namespace turi

#endif
