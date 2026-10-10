# Tạo ví thử nghiệm Monad trên Android

## Quan trọng
Không tạo hoặc in private key trong GitHub Actions, GitHub Codespaces dùng chung, log CI, issue hoặc pull request. Script này phải chạy cục bộ trên thiết bị bạn tin cậy. Không gửi seed phrase/private key cho bất kỳ ai.

## Cách dễ nhất trên Android
1. Cài MetaMask từ trang chính thức https://metamask.io/ (hoặc cửa hàng ứng dụng chính thức).
2. Tạo **ví mới riêng cho testnet**. Ghi seed phrase ra giấy và không chụp/gửi lên mạng.
3. Thêm mạng Monad Testnet:
   - Network name: Monad Testnet
   - RPC URL: https://testnet-rpc.monad.xyz
   - Chain ID: 10143
   - Currency symbol: MON
   - Explorer: https://testnet.monadscan.com/
4. Nhận MON testnet từ faucet chính thức do Monad công bố. Không gửi tiền thật vào địa chỉ thử nghiệm.
5. Mở hợp đồng ME trên MonadScan:
   https://testnet.monadscan.com/address/0x8f90F36D82DB9E73664e91a405486cc8749c1888
6. Kết nối ví testnet và thử với số MON rất nhỏ. Trước khi nhấn Write, xác nhận đúng địa chỉ hợp đồng, số MON gửi, và các tham số giao dịch. Đừng đoán giá trị minMeOut; kiểm tra công thức trong source code trước.

## Nếu dùng Termux và Foundry
Sau khi cài Foundry trong môi trường Termux tương thích, có thể chạy từ bản sao cục bộ của repo:
```bash
bash script/generate-test-wallet.sh
```
Giữ private key trên thiết bị; không commit file chứa khóa và không dán khóa vào chat.
