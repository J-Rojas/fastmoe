#include <torch/extension.h>
#include <torch/torch.h>
#include <cstdio>
#include <iostream>
#include <vector>


#include <cuda.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>                                                                                          
#include <helper_cuda.h> 

// #include "timer.hh"

#include "cublas_wrapper.h"
#include "cuda_stream_manager.h"

#define CEIL(_x_,_y_) (((_x_)-1)/(_y_)+1)


template <typename scalar_t>
__global__
void generate_ptr_offset_kernel(size_t n, const scalar_t* base, size_t stride, const int* offset, const scalar_t** ptrs) {
	size_t idx = threadIdx.x + blockDim.x * blockIdx.x;
	if (idx < n) {
		ptrs[idx] = base + stride * offset[idx];
	}
}


template <typename scalar_t>
void moe_cuda_forward_impl(
        const scalar_t* input,
        const int* d_gate,
        const scalar_t* weight,
        scalar_t* output,
        const size_t batch_size,
        const size_t in_feat,
        const size_t out_feat,
        const size_t num_expert,
        cublasOperation_t transb) {

    auto h = getCudaStreamManager(num_expert);

	scalar_t *input_buf, *output_buf;

	checkCudaErrors(cudaMalloc(&input_buf, sizeof(scalar_t) * batch_size *
				in_feat));
	checkCudaErrors(cudaMalloc(&output_buf, sizeof(scalar_t) * batch_size *
				out_feat));

    int *gate = new int[batch_size];
	int *expert_count = new int[num_expert], *expert_ptr = new int[num_expert];
	memset(expert_count, 0, sizeof(int) * num_expert);

	checkCudaErrors(cudaMemcpy(gate, d_gate, sizeof(int) * batch_size,
				cudaMemcpyDeviceToHost));
	for (int i = 0; i < batch_size; ++i) {
		++expert_count[gate[i]];
	}
	expert_ptr[0] = 0;
	for (int i = 1; i < num_expert; ++i) {
		expert_ptr[i] = expert_ptr[i - 1] + expert_count[i - 1];
	}
	for (int i = 0; i < batch_size; ++i) {
		int target_idx = expert_ptr[gate[i]]++;
#ifdef MOE_DEBUG_SCATTER
		fprintf(stderr, "aln idx %d gate %d tgt %d\n", i, gate[i], target_idx);
#endif
		checkCudaErrors(cudaMemcpyAsync(input_buf + target_idx * in_feat, 
					input + i * in_feat, sizeof(scalar_t) * in_feat,
					cudaMemcpyDeviceToDevice,
					h->getStream(gate[i])));
	}

	scalar_t alpha = 1, beta = 0; 

	for (int i = 0, ptr = 0; i < num_expert; ++i) {
		if (expert_count[i] == 0) {
			continue;
		}
#ifdef MOE_DEBUG_SCATTER
		fprintf(stderr, "gemm %d sz %d\n", i, expert_count[i]);
		fprintf(stderr, "GeMM %d x %d x %d\n", out_feat, expert_count[i],
				in_feat);
#endif
		// Use T(B) x T(A) = T(C) to produce row-major C
		checkCudaErrors(cublasXgemm(h->getHandle(i),
				(transb == CUBLAS_OP_T) ? CUBLAS_OP_N : CUBLAS_OP_T,
				CUBLAS_OP_N,
				out_feat, expert_count[i], in_feat,
				&alpha,
				weight + i * in_feat * out_feat, 
				(transb == CUBLAS_OP_T) ? out_feat : in_feat,
				input_buf + ptr * in_feat, in_feat,
				&beta,
				output_buf + out_feat * ptr,
				out_feat
				));
		ptr += expert_count[i];
	}
	for (int i = batch_size - 1; i >= 0; --i) {
		int target_idx = --expert_ptr[gate[i]];
#ifdef MOE_DEBUG_SCATTER
		fprintf(stderr, "cb idx %d gate %d tgt %d\n", i, gate[i], target_idx);
#endif
		checkCudaErrors(cudaMemcpyAsync(output + i * out_feat,
					output_buf + target_idx * out_feat,
					sizeof(scalar_t) * out_feat,
					cudaMemcpyDeviceToDevice,
					h->getStream(gate[i])));
	}

	h->sync();

	cudaFree(input_buf);
	cudaFree(output_buf);
}

template <typename scalar_t>
void moe_cuda_grad_weight(
        const scalar_t* input,
        const int* gate,
        const scalar_t* grad_output,
        scalar_t* grad_weight, // [num_expert x out_feat x in_feat]
        const size_t batch_size,
        const size_t in_feat,
        const size_t out_feat,
        const size_t num_expert) {

    auto h = getCudaStreamManager(num_expert);
    
    int* gate_host = new int[batch_size];
    scalar_t alpha = 1, beta = 1;
    checkCudaErrors(cudaMemcpy(gate_host, gate, batch_size * sizeof(int), cudaMemcpyDeviceToHost));
    for (size_t i=0; i<batch_size; ++i) {
        checkCudaErrors(cublasSetStream(h->handles[0], *(h->streams + gate_host[i])));
        checkCudaErrors(cublasXgemm(h->handles[0],
            CUBLAS_OP_N, 
            CUBLAS_OP_T,
            out_feat, 
            in_feat, 
            1,
            &alpha,
            grad_output + i * out_feat,
            out_feat,
            input + i * in_feat,
            in_feat,
            &beta,
            grad_weight + gate_host[i] * out_feat * in_feat,
            out_feat));
    }
    for (size_t i=0; i<num_expert; ++i) {
        checkCudaErrors(cudaStreamSynchronize(*(h->streams + i)));
    }
    delete[] gate_host;
}

std::vector<torch::Tensor> moe_cuda_forward(
        torch::Tensor input,
        torch::Tensor gate,
        torch::Tensor weight) {
    const auto batch_size = input.size(0);
    const auto num_expert = weight.size(0);
    const auto out_feat = weight.size(1);
    const auto in_feat = weight.size(2);
            
#ifdef MOE_DEBUG
    printf("[forward] b=%ld, expert=%ld, in_feat (d_model)=%ld, out_feat (d_ffn)=%ld\n", batch_size, num_expert, in_feat, out_feat);
#endif
    auto output = input.new_zeros({batch_size, out_feat});
    
    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "moe_forward_cuda", ([&] {
                moe_cuda_forward_impl<scalar_t>(
                    input.data_ptr<scalar_t>(),
                    gate.data_ptr<int>(),
                    weight.data_ptr<scalar_t>(),
                    output.data_ptr<scalar_t>(),
                    batch_size,
                    in_feat,
                    out_feat,
                    num_expert,
                    CUBLAS_OP_T
                );
    }));
    
    return {output, };           
}

std::vector<torch::Tensor> moe_cuda_backward(
    torch::Tensor grad_output, // [batch_size x out_feat]
    torch::Tensor input, // [batch_size x out_feat]
    torch::Tensor gate,  // [batch_size]
    torch::Tensor weight // [num_expert x out_feat x in_feat]
) {
    const auto batch_size = input.size(0);
    const auto num_expert = weight.size(0);
    const auto out_feat = weight.size(1);
    const auto in_feat = weight.size(2);
#ifdef MOE_DEBUG
    printf("[backward] b=%ld, expert=%ld, in_feat (d_model)=%ld, out_feat (d_ffn)=%ld\n", batch_size, num_expert, in_feat, out_feat);
#endif

    auto grad_input = grad_output.new_zeros({batch_size, in_feat});  // batch_size x in_feat
    auto grad_weight = grad_output.new_zeros({num_expert, out_feat, in_feat}); // num_expert x out_feat x in_feat

    // grad_input is easy to compute, exactly the same as forward
    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "moe_cuda_backward", ([&] {
        moe_cuda_forward_impl<scalar_t>(
            grad_output.data_ptr<scalar_t>(),
            gate.data_ptr<int>(),
            weight.data_ptr<scalar_t>(),
            grad_input.data_ptr<scalar_t>(),
            batch_size,
            out_feat,
            in_feat,
            num_expert,
            CUBLAS_OP_N
        );
    }));

    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "moe_cuda_backward", ([&] {
        moe_cuda_grad_weight<scalar_t>(
            input.data_ptr<scalar_t>(),
            gate.data_ptr<int>(),
            grad_output.data_ptr<scalar_t>(),
            grad_weight.data_ptr<scalar_t>(),
            batch_size,
            in_feat,
            out_feat,
            num_expert
        );
    }));

    return {grad_input, grad_weight};
}


/*
int main() {
    typedef float data_t;
    size_t batch_size = 4096;
    size_t top_k = 2;
    size_t num_expert = 128;
    size_t in_feat = 1024;
    size_t out_feat = 4096;
	data_t *input, *weight;
	data_t *output;
	size_t *gate;

	checkCudaErrors(cudaMalloc(&input, batch_size * in_feat * sizeof(data_t)));
	checkCudaErrors(cudaMalloc(&weight, num_expert * in_feat * out_feat * sizeof(data_t)));	
	checkCudaErrors(cudaMalloc(&output, batch_size * top_k * out_feat * sizeof(data_t)));
    checkCudaErrors(cudaMalloc(&gate, batch_size * top_k * sizeof(size_t)));
    
    size_t nt = 16;
    double tsum = 0, tmax = 0;

    size_t *gate_host = new size_t[batch_size * top_k];
    for (size_t i=0; i<batch_size * top_k; ++i) {
        gate_host[i] = rand() % num_expert;
    } 
    checkCudaErrors(cudaMemcpy(gate, gate_host, batch_size * top_k * sizeof(size_t), cudaMemcpyHostToDevice));

    moe_first_linear_cuda_forward<data_t>(input, gate, weight, output, batch_size, top_k, in_feat, out_feat);
    
    for (size_t i=0; i<nt; ++i) {
        timestamp(start);
		moe_first_linear_cuda_forward<data_t>(input, gate, weight, output, batch_size, top_k, in_feat, out_feat);
		timestamp(end);
		auto t = getDuration(start, end);
		tsum += t;
		if (t > tmax) tmax = t;
    }
    printf("Mean %.3lf us, max %.3lf us\n", tsum / nt * 1e6, tmax * 1e6);
	double tflops = (double)batch_size * top_k * in_feat * out_feat * nt * 2e-12 / tsum;
	printf("%.3lf TFLOPs\n", tflops);
}
*/
