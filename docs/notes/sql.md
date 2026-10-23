STORED AS TEXTFILE/ORC/Parquet --存储方式，不写默认TEXTFILE

TBLPROPERTIES ()                               --给表做附加自定义属性的键值对 

eg:

'orc.compress' = 'snap'                       --压缩方式

'orc.bloom.filter.columns' = 'product_id,user_id'    --




