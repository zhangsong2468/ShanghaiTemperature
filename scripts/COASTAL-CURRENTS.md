# 沿岸表层海流叠加层

仅地图小组件获取并绘制五个海面点的即时模型表层流，不计算24小时平均，也不声称剔除了河流、波浪和潮汐影响。数据来自 Open-Meteo Marine API 的 current ocean_current_velocity 与 ocean_current_direction，单位 m/s，方向表示水流去向。模型数据可能是逐小时产品的时间插值，每10分钟请求不意味着模型每10分钟更新。

五点覆盖江苏北段、江苏南段、上海外海、浙江北段、浙江南段。使用接口实际返回的网格坐标，拒绝偏离目标超过0.25度的网格，跳过缺测、重复网格、未来或超过1小时的样本。大陆边界来自现有地图，无法表达粗轮廓未包含的小岛与海岸细节。

单次成功接收后显示120秒。缓存读取、其他图层刷新及进程重启不延长这段时间。正常请求最小间隔600秒；并发合并，间隔状态原子保存于小组件沙盒 Application Support/ShanghaiTemperature-CoastalCurrent-v1。失败隐藏图层，429/503至少等待10分钟并遵守更长的Retry-After。无主App请求，无共享沙盒权限变更。

箭头为固定细线宽、统一灰色，长度及透明度随速度连续增加，有显示上限。方向由实际流向决定；零速度不画箭头。使用小组件当前条目的时间判定有效期，给120秒截止时间安排隐藏条目。海面裁剪后绘制在城市名、温度范围与飞机图层下方，保留现有地图内容、范围及尺寸。

目标是10分钟获取、2分钟后隐藏；WidgetKit调度、预算和睡眠可能延迟网络请求与隐藏条目，不能保证秒级准时。主App仍不展示此层；飞机、温度、潮位逻辑保持原样。

验证：python3 scripts/check-coastal-currents.py 为结构检查，--live 单次验证真实五点接口。Tests/CoastalCurrentTests.swift 覆盖即时字段、方向、缺测、单位、到期、并发、持久化及限流，需完整Swift工具链。实际桌面图形和系统调度仍需安装验证。

数据与许可：Open-Meteo Marine Weather API https://open-meteo.com/en/docs/marine-weather-api ，Météo-France / E.U. Copernicus Marine SMOC；来源许可随原有数据来源说明保留。
